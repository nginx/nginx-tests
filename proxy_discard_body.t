#!/usr/bin/perl

# (C) Elijah Zupancic
# (C) F5, Inc.

# Tests for http proxy module, request body being discarded.

###############################################################################

use warnings;
use strict;

use Test::More;

use Socket qw/ CRLF /;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/http http_v2 proxy rewrite/)->plan(4);

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

        lingering_timeout 2s;

        location / {
            client_max_body_size 1;
            error_page 413 = @proxy;
        }

        location /h2/ {
            client_max_body_size 1;
            error_page 413 = @proxy_h2;
        }

        location @proxy {
            proxy_pass http://127.0.0.1:8081;
            proxy_read_timeout 1s;
        }

        location @proxy_h2 {
            proxy_http_version 2;
            proxy_pass http://127.0.0.1:8081;
            proxy_read_timeout 1s;
        }
    }

    server {
        listen       127.0.0.1:8081;
        server_name  localhost;

        http2 on;

        location / {
            add_header X-Content-Length "[$content_length]";
            proxy_pass http://127.0.0.1:8082;
        }
    }

    server {
        listen       127.0.0.1:8082;
        server_name  localhost;

        location / {
            return 200 "ok\n";
        }
    }
}

EOF

$t->run();

###############################################################################

# while the request body is being discarded, the upstream request is
# expected to describe the body actually sent, that is, either an empty
# body or no body at all; previously, the remaining Content-Length was
# used, and the request hung until proxy_read_timeout, or was rejected
# by an HTTP/2 upstream

TODO: {
local $TODO = 'not yet' unless $t->has_version('1.31.9');

my $r = post('/', 'Content-Length: 10');

like($r, qr/ 200 /, 'discarded body proxied');
like($r, qr/X-Content-Length: \[0?\]\x0d?$/m, 'discarded body content length');

$r = post('/h2/', 'Content-Length: 10');

like($r, qr/ 200 /, 'discarded body proxied with http2');
like($r, qr/X-Content-Length: \[0?\]\x0d?$/mi,
	'discarded body content length with http2');

}

###############################################################################

sub post {
	my ($uri, $header) = @_;

	return http(
		"POST $uri HTTP/1.1" . CRLF
		. 'Host: localhost' . CRLF
		. 'Connection: close' . CRLF
		. $header . CRLF . CRLF
	);
}

###############################################################################
