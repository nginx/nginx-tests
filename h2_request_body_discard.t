#!/usr/bin/perl

# (C) Maxim Dounin

# Tests for discarding request body with HTTP/2.

###############################################################################

use warnings;
use strict;

use Test::More;
use Socket qw/ CRLF /;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;
use Test::Nginx::HTTP2;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()
	->has(qw/http http_v2 proxy rewrite addition memcached/);


$t->plan(38)->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        http2 on;

        lingering_timeout 1s;
        add_header X-Body body:$content_length:$request_body:;

        client_max_body_size 1k;

        error_page 400 /proxy/error400;

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

$t->run();

###############################################################################

# error_page 413 should work without redefining client_max_body_size

like(http2_get_body('/', '0123456789' x 128),
	qr/status: 413.*custom error 413/s, 'custom error 413');

# subrequest after discarding body

like(http2_get('/add'),
	qr/backend body:::.*main response/s, 'add');
like(http2_get_body('/add', '0123456789'),
	qr/backend body:::.*main response/s, 'add small');
like(http2_get_body_incomplete('/add', 10000, '0123456789'),
	qr/backend body:::.*main response/s, 'add long');
like(http2_get_body_nolen('/add', '0123456789'),
	qr/backend body:::.*main response/s, 'add nolen');
like(http2_get_body_nolen('/add', '0', '123456789'),
	qr/backend body:::.*main response/s, 'add nolen multi');
like(http2_get_body_incomplete_nolen('/add', 10000, '0123456789'),
	qr/backend body:::.*main response/s, 'add chunked long');

# error_page 502 with proxy_pass after discarding body

like(http2_get('/memcached'),
	qr/backend body:::/s, 'memcached');
like(http2_get_body('/memcached', '0123456789'),
	qr/status: 502.*backend body:::/s, 'memcached small');
like(http2_get_body_incomplete('/memcached', 10000, '0123456789'),
	qr/status: 502.*backend body:::/s, 'memcached long');
like(http2_get_body_nolen('/memcached', '0123456789'),
	qr/status: 502.*backend body:::/s, 'memcached nolen');
like(http2_get_body_nolen('/memcached', '0', '123456789'),
	qr/status: 502.*backend body:::/s, 'memcached nolen multi');
like(http2_get_body_incomplete_nolen('/memcached', 10000, '0123456789'),
	qr/status: 502.*backend body:::/s, 'memcached nolen long');

# error_page 413 with proxy_pass

like(http2_get('/proxy'),
	qr/status: 502.*backend body:::/s, 'proxy');
like(http2_get_body('/proxy', '0123456789'),
	qr/status: 413.*backend body:::/s, 'proxy small');
like(http2_get_body_incomplete('/proxy', 10000, '0123456789'),
	qr/status: 413.*backend body:::/s, 'proxy long');
like(http2_get_body_nolen('/proxy', '0123456789'),
	qr/status: 413.*backend body:::/s, 'proxy nolen');
like(http2_get_body_nolen('/proxy', '0', '123456789'),
	qr/status: 413.*backend body:::/s, 'proxy nolen multi');
like(http2_get_body_incomplete_nolen('/proxy', 10000, '0123456789'),
	qr/status: 413.*backend body:::/s, 'proxy nolen long');

# error_page 400 with proxy_pass

# note that "proxy too short" test triggers 400 during parsing
# request headers, and therefore needs error_page at server level

like(http2_get_body_custom('/proxy', 1),
	qr/status: 400.*backend body:::/s, 'proxy too short');
like(http2_get_body_custom('/proxy', 1, ''),
	qr/status: 400.*backend body:::/s, 'proxy too short body');
like(http2_get_body_custom('/proxy', 1, '01'),
	qr/status: 400.*backend body:::/s, 'proxy too long');
like(http2_get_body_custom('/proxy', 1, '01', more => 1),
	qr/status: 400.*backend body:::/s, 'proxy too long more');

# error_page 502 after proxy with request buffering disabled

like(http2_get('/unbuf'),
	qr/status: 502.*backend body:::/s, 'unbuf proxy');
like(http2_get_body('/unbuf', '0123456789'),
	qr/status: 502.*backend body:::/s, 'unbuf proxy small');
like(http2_get_body_incomplete('/unbuf', 10000, '0123456789'),
	qr/status: 502.*backend body:::/s, 'unbuf proxy long');
like(http2_get_body_nolen('/unbuf', '0123456789'),
	qr/status: 502.*backend body:::/s, 'unbuf proxy nolen');
like(http2_get_body_nolen('/unbuf', '0', '123456789'),
	qr/status: 502.*backend body:::/s, 'unbuf proxy nolen multi');
like(http2_get_body_incomplete_nolen('/unbuf', 10000, '0123456789'),
	qr/status: 502.*backend body:::/s, 'unbuf proxy nolen long');

# error_page 400 after proxy with request buffering disabled

like(http2_get_body_custom('/unbuf2', 1, '', sleep => 0.2),
	qr/status: 400.*backend body:::/s, 'unbuf too short');
like(http2_get_body_custom('/unbuf2', 1, '01', sleep => 0.2),
	qr/status: 400.*backend body:::/s, 'unbuf too long');
like(http2_get_body_custom('/unbuf2', 1, '01', sleep => 0.2, more => 1),
	qr/status: 400.*backend body:::/s, 'unbuf too long more');

# error_page 413 and $content_length
# (used in fastcgi_pass, grpc_pass, uwsgi_pass)

like(http2_get('/length'),
	qr/status: 502.*frontend body:::/s, '$content_length');
like(http2_get_body('/length', '0123456789'),
	qr/status: 413.*frontend body:::/s, '$content_length small');
like(http2_get_body_incomplete('/length', 10000, '0123456789'),
	qr/status: 413.*frontend body:::/s, '$content_length long');
like(http2_get_body_nolen('/length', '0123456789'),
	qr/status: 413.*frontend body:::/s, '$content_length nolen');
like(http2_get_body_nolen('/length', '0', '123456789'),
	qr/status: 413.*frontend body:::/s, '$content_length nolen multi');
like(http2_get_body_incomplete_nolen('/length', 10000, '0123456789'),
	qr/status: 413.*frontend body:::/s, '$content_length nolen long');

###############################################################################

sub http2_get {
	my ($uri) = @_;

	my $s = Test::Nginx::HTTP2->new();
	my $sid = $s->new_stream({ path => $uri });
	my $frames = $s->read(all => [{ sid => $sid, fin => 1 }]);

	my ($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
	my ($data) = grep { $_->{type} eq "DATA" } @$frames;

	return join("\n", map { "$_: " . $frame->{headers}->{$_}; }
		keys %{$frame->{headers}}) . "\n\n" . $data->{data};
}

sub http2_get_body {
	my ($uri, $body) = @_;

	my $s = Test::Nginx::HTTP2->new();
	my $sid = $s->new_stream({ path => $uri, body => $body });
	my $frames = $s->read(all => [{ sid => $sid, fin => 1 }]);

	my ($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
	my ($data) = grep { $_->{type} eq "DATA" } @$frames;

	return join("\n", map { "$_: " . $frame->{headers}->{$_}; }
		keys %{$frame->{headers}}) . "\n\n" . $data->{data};
}

sub http2_get_body_nolen {
	my ($uri, $body, $body2) = @_;

	my $s = Test::Nginx::HTTP2->new();
	my $sid = $s->new_stream({ path => $uri, body_more => 1 });

	if (defined $body2) {
		$s->h2_body($body, { body_more => 1 });
		$s->h2_body($body2);
	} else {
		$s->h2_body($body);
	}

	my $frames = $s->read(all => [{ sid => $sid, fin => 1 }]);

	my ($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
	my ($data) = grep { $_->{type} eq "DATA" } @$frames;

	return join("\n", map { "$_: " . $frame->{headers}->{$_}; }
		keys %{$frame->{headers}}) . "\n\n" . $data->{data};
}

sub http2_get_body_incomplete {
	my ($uri, $len, $body) = @_;

	my $s = Test::Nginx::HTTP2->new();
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
	$s->h2_body($body, { body_more => 1 });

	my $frames = $s->read(all => [{ sid => $sid, fin => 1 }]);

	my ($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
	my ($data) = grep { $_->{type} eq "DATA" } @$frames;

	return join("\n", map { "$_: " . $frame->{headers}->{$_}; }
		keys %{$frame->{headers}}) . "\n\n" . $data->{data};
}

sub http2_get_body_incomplete_nolen {
	my ($uri, $len, $body) = @_;

	my $s = Test::Nginx::HTTP2->new();
	my $sid = $s->new_stream({ path => $uri, body_more => 1 });
	$s->h2_body($body, { body_more => 1 });

	my $frames = $s->read(all => [{ sid => $sid, fin => 1 }]);

	my ($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
	my ($data) = grep { $_->{type} eq "DATA" } @$frames;

	return join("\n", map { "$_: " . $frame->{headers}->{$_}; }
		keys %{$frame->{headers}}) . "\n\n" . $data->{data};
}

sub http2_get_body_custom {
	my ($uri, $len, $body, %extra) = @_;

	my $s = Test::Nginx::HTTP2->new();
	my $sid = $s->new_stream({
		headers => [
			{ name => ':method', value => 'GET' },
			{ name => ':scheme', value => 'http' },
			{ name => ':path', value => $uri },
			{ name => ':authority', value => 'localhost' },
			{ name => 'content-length', value => $len },
		],
		body_more => (defined $body ? 1 : undef)
	});

	if (defined $body) {
		select undef, undef, undef, $extra{sleep} if $extra{sleep};
		$s->h2_body($body, { body_more => 1 });
		$s->h2_body('') unless $extra{more};
	}

	my $frames = $s->read(all => [{ sid => $sid, fin => 1 }]);

	my ($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
	my ($data) = grep { $_->{type} eq "DATA" } @$frames;

	return join("\n", map { "$_: " . $frame->{headers}->{$_}; }
		keys %{$frame->{headers}}) . "\n\n" . $data->{data};
}

###############################################################################
