#!/usr/bin/perl

# Tests for forward proxy IPv6 targets.

###############################################################################

use warnings;
use strict;

use Test::More;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;
use Test::Nginx::HTTP2;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

plan(skip_all => 'win32') if $^O eq 'MSWin32';

my $t = Test::Nginx->new()->has(qw/http proxy http_v2/);

$t->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        location / {
            forward_proxy on;
            proxy_connect_timeout 2s;
            proxy_read_timeout 2s;
            proxy_send_timeout 2s;
        }
    }

    server {
        listen       127.0.0.1:8082;
        server_name  localhost;

        http2 on;

        location / {
            forward_proxy on;
            proxy_connect_timeout 2s;
            proxy_read_timeout 2s;
            proxy_send_timeout 2s;
        }
    }

    server {
        listen       [::1]:%%PORT_8081%%;
        server_name  localhost;

        location / {
            add_header X-Method $request_method always;
            add_header X-URI $request_uri always;
            add_header X-Host $http_host always;
            return 200 "method=$request_method\nuri=$request_uri\nhost=$http_host\n";
        }
    }
}

EOF

$t->try_run('no inet6 support')->plan(4);

###############################################################################

my $p = port(8081);

my $r = http(<<"EOF");
GET http://[::1]:$p/ipv6?x=1 HTTP/1.1
Host: ignored.example
Connection: close

EOF
like($r, qr/^HTTP\/1\.1 200 OK/ms, 'h1 ipv6 forward proxy request');
like($r, qr/X-Host: \[::1\]:$p/i, 'h1 ipv6 target preserves Host');

my ($headers, $body) = h2_forward(
	path => '/h2-ipv6',
	host => "[::1]:$p",
);
is($headers->{':status'}, '200', 'h2 ipv6 forward proxy request');
like($body, qr/method=GET\nuri=\/h2-ipv6\nhost=\[::1\]:$p\n/s,
	'h2 ipv6 target preserves Host');

###############################################################################

sub h2_forward {
	my (%args) = @_;

	my $s = Test::Nginx::HTTP2->new(port(8082), pure => 1);
	my $sid = $s->new_stream({
		method => 'GET',
		scheme => 'http',
		path => $args{path},
		host => $args{host},
	});

	my $frames = $s->read(all => [{ sid => $sid, fin => 1 }], wait => 2);
	my ($headers) = map { $_->{headers} } grep { $_->{type} eq 'HEADERS' } @$frames;
	my $body = join('', map { $_->{data} } grep { $_->{type} eq 'DATA' } @$frames);

	return ($headers, $body);
}

###############################################################################
