#!/usr/bin/perl

# (C) Maxim Dounin

# Tests for discarding request body with HTTP/3.

###############################################################################

use warnings;
use strict;

use Test::More;
use Socket qw/ CRLF /;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;
use Test::Nginx::HTTP3;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()
	->has(qw/http http_v3 proxy rewrite addition memcached cryptx/)
	->has_daemon('openssl');


$t->plan(37)->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    ssl_certificate localhost.crt;
    ssl_certificate_key localhost.key;

    server {
        listen       127.0.0.1:%%PORT_8980_UDP%% quic;
        server_name  localhost;

        lingering_timeout 1s;
        add_header X-Body body:$content_length:$request_body:;

        client_max_body_size 1k;

        location / {
            error_page 413 /error413;
            proxy_pass http://127.0.0.1:8082;
        }

        location /error413 {
            return 200 "custom error 413";
        }

        location /add {
            return 200 "main response";
            add_before_body /add/before;
            addition_types *;
            client_max_body_size 1m;
        }

        location /add/before {
            proxy_pass http://127.0.0.1:8081;
        }

        location /memcached {
            client_max_body_size 1m;
            error_page 502 /memcached/error502;
            memcached_pass 127.0.0.1:8083;
            set $memcached_key $request_uri;
        }

        location /memcached/error502 {
            proxy_pass http://127.0.0.1:8081;
        }

        location /proxy {
            client_max_body_size 3;
            error_page 413 /proxy/error413;
            error_page 400 /proxy/error400;
            error_page 502 /proxy/error502;
            proxy_pass http://127.0.0.1:8083;
        }

        location /proxy/error413 {
            proxy_pass http://127.0.0.1:8081;
        }

        location /proxy/error400 {
            proxy_pass http://127.0.0.1:8081;
        }

        location /proxy/error502 {
            proxy_pass http://127.0.0.1:8081;
        }

        location /unbuf {
            client_max_body_size 1m;
            error_page 502 /unbuf/error502;
            proxy_pass http://127.0.0.1:8083;
            proxy_request_buffering off;
            proxy_http_version 1.1;
        }

        location /unbuf/error502 {
            client_max_body_size 1m;
            proxy_pass http://127.0.0.1:8081;
        }

        location /unbuf2 {
            client_max_body_size 1m;
            error_page 400 /unbuf2/error400;
            proxy_pass http://127.0.0.1:8081;
            proxy_request_buffering off;
            proxy_http_version 1.1;
        }

        location /unbuf2/error400 {
            client_max_body_size 1m;
            proxy_pass http://127.0.0.1:8081;
        }

        location /length {
            client_max_body_size 1;
            error_page 413 /length/error413;
            error_page 502 /length/error502;
            proxy_pass http://127.0.0.1:8083;
        }

        location /length/error413 {
            return 200 "frontend body:$content_length:$request_body:";
        }

        location /length/error502 {
            return 200 "frontend body:$content_length:$request_body:";
        }
    }

    server {
        listen       127.0.0.1:8081;
        server_name  localhost;

        location / {
            proxy_pass http://127.0.0.1:8082;
            proxy_set_header X-Body body:$content_length:$request_body:;
        }
    }

    server {
        listen       127.0.0.1:8082;
        server_name  localhost;

        return 200 "backend $http_x_body";
    }

    server {
        listen       127.0.0.1:8083;
        server_name  localhost;

        return 444;
    }
}

EOF

$t->write_file('openssl.conf', <<EOF);
[ req ]
default_bits = 2048
encrypt_key = no
distinguished_name = req_distinguished_name
[ req_distinguished_name ]
EOF

my $d = $t->testdir();

foreach my $name ('localhost') {
	system('openssl req -x509 -new '
		. "-config $d/openssl.conf -subj /CN=$name/ "
		. "-out $d/$name.crt -keyout $d/$name.key "
		. ">>$d/openssl.out 2>&1") == 0
		or die "Can't create certificate for $name: $!\n";
}

$t->run();

###############################################################################

# error_page 413 should work without redefining client_max_body_size

like(http3_get_body('/', '0123456789' x 128),
	qr/status: 413.*custom error 413/s, 'custom error 413');

# subrequest after discarding body

like(http3_get('/add'),
	qr/backend body:::.*main response/s, 'add');
like(http3_get_body('/add', '0123456789'),
	qr/backend body:::.*main response/s, 'add small');
like(http3_get_body_incomplete('/add', 10000, '0123456789'),
	qr/backend body:::.*main response/s, 'add long');
like(http3_get_body_nolen('/add', '0123456789'),
	qr/backend body:::.*main response/s, 'add nolen');
like(http3_get_body_nolen('/add', '0', '123456789'),
	qr/backend body:::.*main response/s, 'add nolen multi');
like(http3_get_body_incomplete_nolen('/add', 10000, '0123456789'),
	qr/backend body:::.*main response/s, 'add chunked long');

# error_page 502 with proxy_pass after discarding body

like(http3_get('/memcached'),
	qr/backend body:::/s, 'memcached');
like(http3_get_body('/memcached', '0123456789'),
	qr/status: 502.*backend body:::/s, 'memcached small');
like(http3_get_body_incomplete('/memcached', 10000, '0123456789'),
	qr/status: 502.*backend body:::/s, 'memcached long');
like(http3_get_body_nolen('/memcached', '0123456789'),
	qr/status: 502.*backend body:::/s, 'memcached nolen');
like(http3_get_body_nolen('/memcached', '0', '123456789'),
	qr/status: 502.*backend body:::/s, 'memcached nolen multi');
like(http3_get_body_incomplete_nolen('/memcached', 10000, '0123456789'),
	qr/status: 502.*backend body:::/s, 'memcached nolen long');

# error_page 413 with proxy_pass

like(http3_get('/proxy'),
	qr/status: 502.*backend body:::/s, 'proxy');
like(http3_get_body('/proxy', '0123456789'),
	qr/status: 413.*backend body:::/s, 'proxy small');
like(http3_get_body_incomplete('/proxy', 10000, '0123456789'),
	qr/status: 413.*backend body:::/s, 'proxy long');
like(http3_get_body_nolen('/proxy', '0123456789'),
	qr/status: 413.*backend body:::/s, 'proxy nolen');
like(http3_get_body_nolen('/proxy', '0', '123456789'),
	qr/status: 413.*backend body:::/s, 'proxy nolen multi');
like(http3_get_body_incomplete_nolen('/proxy', '0123456789'),
	qr/status: 413.*backend body:::/s, 'proxy nolen long');

# error_page 400 with proxy_pass

like(http3_get_body_custom('/proxy', 1, ''),
	qr/status: 400.*backend body:::/s, 'proxy too short');
like(http3_get_body_custom('/proxy', 1, '01'),
	qr/status: 400.*backend body:::/s, 'proxy too long');
like(http3_get_body_custom('/proxy', 1, '01', more => 1),
	qr/status: 400.*backend body:::/s, 'proxy too long more');

# error_page 502 after proxy with request buffering disabled

like(http3_get('/unbuf'),
	qr/status: 502.*backend body:::/s, 'unbuf proxy');
like(http3_get_body_custom('/unbuf', 10, '0123456789', sleep => 0.2),
	qr/status: 502.*backend body:::/s, 'unbuf proxy small');
like(http3_get_body_incomplete('/unbuf', 10000, '0123456789'),
	qr/status: 502.*backend body:::/s, 'unbuf proxy long');
like(http3_get_body_nolen('/unbuf', '0123456789'),
	qr/status: 502.*backend body:::/s, 'unbuf proxy nolen');
like(http3_get_body_nolen('/unbuf', '0', '123456789'),
	qr/status: 502.*backend body:::/s, 'unbuf proxy nolen multi');
like(http3_get_body_incomplete_nolen('/unbuf', 10000, '0123456789'),
	qr/status: 502.*backend body:::/s, 'unbuf proxy nolen long');

# error_page 400 after proxy with request buffering disabled

like(http3_get_body_custom('/unbuf2', 1, '', sleep => 0.2),
	qr/status: 400.*backend body:::/s, 'unbuf too short');
like(http3_get_body_custom('/unbuf2', 1, '01', sleep => 0.2),
	qr/status: 400.*backend body:::/s, 'unbuf too long');
like(http3_get_body_custom('/unbuf2', 1, '01', sleep => 0.2, more => 1),
	qr/status: 400.*backend body:::/s, 'unbuf too long more');

# error_page 413 and $content_length
# (used in fastcgi_pass, grpc_pass, uwsgi_pass)

like(http3_get('/length'),
	qr/status: 502.*frontend body:::/s, '$content_length');
like(http3_get_body('/length', '0123456789'),
	qr/status: 413.*frontend body:::/s, '$content_length small');
like(http3_get_body_incomplete('/length', 10000, '0123456789'),
	qr/status: 413.*frontend body:::/s, '$content_length long');
like(http3_get_body_nolen('/length', '0123456789'),
	qr/status: 413.*frontend body:::/s, '$content_length nolen');
like(http3_get_body_nolen('/length', '0', '123456789'),
	qr/status: 413.*frontend body:::/s, '$content_length nolen multi');
like(http3_get_body_incomplete_nolen('/length', 10000, '0123456789'),
	qr/status: 413.*frontend body:::/s, '$content_length nolen long');

###############################################################################

sub http3_get {
	my ($uri) = @_;

	my $s = Test::Nginx::HTTP3->new();
	my $sid = $s->new_stream({ path => $uri });
	my $frames = $s->read(all => [{ sid => $sid, fin => 1 }]);

	my ($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
	my (@data) = grep { $_->{type} eq "DATA" } @$frames;

	return join("\n", map { "$_: " . $frame->{headers}->{$_}; }
		keys %{$frame->{headers}}) . "\n\n"
		.  join("", map { $_->{data} } @data);
}

sub http3_get_body {
	my ($uri, $body) = @_;

	my $s = Test::Nginx::HTTP3->new();
	my $sid = $s->new_stream({ path => $uri, body => $body });
	my $frames = $s->read(all => [{ sid => $sid, fin => 1 }]);

	my ($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
	my (@data) = grep { $_->{type} eq "DATA" } @$frames;

	return join("\n", map { "$_: " . $frame->{headers}->{$_}; }
		keys %{$frame->{headers}}) . "\n\n"
		.  join("", map { $_->{data} } @data);
}

sub http3_get_body_nolen {
	my ($uri, $body, $body2) = @_;

	my $s = Test::Nginx::HTTP3->new();
	my $sid = $s->new_stream({ path => $uri, body_more => 1 });

	if (defined $body2) {
		select undef, undef, undef, 0.2;
		$s->h3_body($body, $sid, { body_more => 1 });
		select undef, undef, undef, 0.2;
		$s->h3_body($body2, $sid);
	} else {
		select undef, undef, undef, 0.2;
		$s->h3_body($body, $sid);
	}

	my $frames = $s->read(all => [{ sid => $sid, fin => 1 }]);

	my ($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
	my (@data) = grep { $_->{type} eq "DATA" } @$frames;

	return join("\n", map { "$_: " . $frame->{headers}->{$_}; }
		keys %{$frame->{headers}}) . "\n\n"
		.  join("", map { $_->{data} } @data);
}

sub http3_get_body_incomplete {
	my ($uri, $len, $body) = @_;

	my $s = Test::Nginx::HTTP3->new();
	my $sid = $s->new_stream({
		headers => [
			{ name => ':method', value => 'GET' },
			{ name => ':scheme', value => 'http' },
			{ name => ':path', value => $uri },
			{ name => ':authority', value => 'localhost' },
			{ name => 'content-length', value => $len },
		],
		body_more => 1
	});
	$s->h3_body($body, $sid, { body_more => 1 });

	my $frames = $s->read(all => [{ sid => $sid, fin => 1 }]);

	my ($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
	my (@data) = grep { $_->{type} eq "DATA" } @$frames;

	return join("\n", map { "$_: " . $frame->{headers}->{$_}; }
		keys %{$frame->{headers}}) . "\n\n"
		.  join("", map { $_->{data} } @data);
}

sub http3_get_body_incomplete_nolen {
	my ($uri, $body) = @_;

	my $s = Test::Nginx::HTTP3->new();
	my $sid = $s->new_stream({ path => $uri, body_more => 1 });
	$s->h3_body($body, $sid, { body_more => 1 });

	my $frames = $s->read(all => [{ sid => $sid, fin => 1 }]);

	my ($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
	my (@data) = grep { $_->{type} eq "DATA" } @$frames;

	return join("\n", map { "$_: " . $frame->{headers}->{$_}; }
		keys %{$frame->{headers}}) . "\n\n"
		.  join("", map { $_->{data} } @data);
}

sub http3_get_body_custom {
	my ($uri, $len, $body, %extra) = @_;

	my $s = Test::Nginx::HTTP3->new();
	my $sid = $s->new_stream({
		headers => [
			{ name => ':method', value => 'GET' },
			{ name => ':scheme', value => 'http' },
			{ name => ':path', value => $uri },
			{ name => ':authority', value => 'localhost' },
			{ name => 'content-length', value => $len },
		],
		body_more => 1
	});
	select undef, undef, undef, $extra{sleep} if $extra{sleep};
	$s->h3_body($body, $sid, { body_more => 1 });
	$s->h3_body('', $sid) unless $extra{more};

	my $frames = $s->read(all => [{ sid => $sid, fin => 1 }]);

	my ($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
	my (@data) = grep { $_->{type} eq "DATA" } @$frames;

	return join("\n", map { "$_: " . $frame->{headers}->{$_}; }
		keys %{$frame->{headers}}) . "\n\n"
		.  join("", map { $_->{data} } @data);
}

###############################################################################
