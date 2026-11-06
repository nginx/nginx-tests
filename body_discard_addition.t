#!/usr/bin/perl

# (C) Maxim Dounin
# (C) Nginx, Inc.

# Tests for discarding request body with the addition module.

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

my $t = Test::Nginx->new()
	->has(qw/http proxy rewrite addition/);

plan(skip_all => 'not yet') unless $t->has_version('1.31.9');

$t->plan(6)->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    server {
        listen       127.0.0.1:8080;
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

$t->run();

###############################################################################

# subrequest after discarding body

like(http(
	'GET /add HTTP/1.0' . CRLF . CRLF
), qr/backend body:::.*main response/s, 'add');

like(http(
	'POST /add HTTP/1.0' . CRLF .
	'Content-Length: 10' . CRLF . CRLF .
	'0123456789'
), qr/backend body:::.*main response/s, 'add small');

like(http(
	'POST /add HTTP/1.0' . CRLF .
	'Content-Length: 10000' . CRLF . CRLF .
	'0123456789'
), qr/backend body:::.*main response/s, 'add long');

like(http(
	'POST /add HTTP/1.1' . CRLF .
	'Host: localhost' . CRLF .
	'Connection: close' . CRLF .
	'Transfer-Encoding: chunked' . CRLF . CRLF .
	'a' . CRLF .
	'0123456789' . CRLF .
	'0' . CRLF . CRLF
), qr/backend body:::.*main response/s, 'add chunked');

like(http(
	'POST /add HTTP/1.1' . CRLF .
	'Host: localhost' . CRLF .
	'Connection: close' . CRLF .
	'Transfer-Encoding: chunked' . CRLF . CRLF .
	'1' . CRLF .
	'X' . CRLF .
	'9' . CRLF .
	'123456789' . CRLF .
	'0' . CRLF . CRLF
), qr/backend body:::.*main response/s, 'add chunked multi');

like(http(
	'POST /add HTTP/1.1' . CRLF .
	'Host: localhost' . CRLF .
	'Connection: close' . CRLF .
	'Transfer-Encoding: chunked' . CRLF . CRLF .
	'ffff' . CRLF .
	'0123456789'
), qr/backend body:::.*main response/s, 'add chunked long');

