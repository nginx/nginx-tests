#!/usr/bin/perl

# (C) Maxim Dounin
# (C) Nginx, Inc.

# Tests for discarding request body with HTTP/3 and the addition module.

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
	->has(qw/http http_v3 proxy rewrite addition cryptx/)
	->has_daemon('openssl');

plan(skip_all => 'not yet') unless $t->has_version('1.31.10');

$t->plan(6)->write_file_expand('nginx.conf', <<'EOF');

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

        location /add {
            return 200 "main response";
            add_before_body /add/before;
            addition_types *;
            client_max_body_size 1m;
        }

        location /add/before {
            proxy_pass http://127.0.0.1:8081;
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

###############################################################################
