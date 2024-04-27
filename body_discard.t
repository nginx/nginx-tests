#!/usr/bin/perl

# (C) Maxim Dounin

# Tests for discarding request body.

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
	->has(qw/http proxy rewrite addition memcached/);


$t->plan(33)->write_file_expand('nginx.conf', <<'EOF');

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
            client_max_body_size 1;
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

like(http(
	'POST / HTTP/1.0' . CRLF .
	'Content-Length: 10000' . CRLF . CRLF .
	'0123456789'
), qr/ 413 .*custom error 413/s, 'custom error 413');

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

# error_page 502 with proxy_pass after discarding body

like(http(
	'GET /memcached HTTP/1.0' . CRLF . CRLF
), qr/ 502 .*backend body:::/s, 'memcached');

like(http(
	'GET /memcached HTTP/1.0' . CRLF .
	'Content-Length: 10' . CRLF . CRLF .
	'0123456789'
), qr/ 502 .*backend body:::/s, 'memcached small');

like(http(
	'GET /memcached HTTP/1.0' . CRLF .
	'Content-Length: 10000' . CRLF . CRLF .
	'0123456789'
), qr/ 502 .*backend body:::/s, 'memcached long');

like(http(
	'GET /memcached HTTP/1.1' . CRLF .
	'Host: localhost' . CRLF .
	'Connection: close' . CRLF .
	'Transfer-Encoding: chunked' . CRLF . CRLF .
	'a' . CRLF .
	'0123456789' . CRLF .
	'0' . CRLF . CRLF
), qr/ 502 .*backend body:::/s, 'memcached chunked');

like(http(
	'GET /memcached HTTP/1.1' . CRLF .
	'Host: localhost' . CRLF .
	'Connection: close' . CRLF .
	'Transfer-Encoding: chunked' . CRLF . CRLF .
	'1' . CRLF .
	'X' . CRLF .
	'9' . CRLF .
	'123456789' . CRLF .
	'0' . CRLF . CRLF
), qr/ 502 .*backend body:::/s, 'memcached chunked multi');

like(http(
	'GET /memcached HTTP/1.1' . CRLF .
	'Host: localhost' . CRLF .
	'Connection: close' . CRLF .
	'Transfer-Encoding: chunked' . CRLF . CRLF .
	'ffff' . CRLF .
	'0123456789'
), qr/ 502 .*backend body:::/s, 'memcached chunked long');

# error_page 413 with proxy_pass

like(http(
	'GET /proxy HTTP/1.0' . CRLF . CRLF
), qr/ 502 .*backend body:::/s, 'proxy');

like(http(
	'POST /proxy HTTP/1.0' . CRLF .
	'Content-Length: 10' . CRLF . CRLF .
	'0123456789'
), qr/ 413 .*backend body:::/s, 'proxy small');

like(http(
	'POST /proxy HTTP/1.0' . CRLF .
	'Content-Length: 10000' . CRLF . CRLF .
	'0123456789'
), qr/ 413 .*backend body:::/s, 'proxy long');

like(http(
	'POST /proxy HTTP/1.1' . CRLF .
	'Host: localhost' . CRLF .
	'Connection: close' . CRLF .
	'Transfer-Encoding: chunked' . CRLF . CRLF .
	'a' . CRLF .
	'0123456789' . CRLF .
	'0' . CRLF . CRLF
), qr/ 413 .*backend body:::/s, 'proxy chunked');

like(http(
	'POST /proxy HTTP/1.1' . CRLF .
	'Host: localhost' . CRLF .
	'Connection: close' . CRLF .
	'Transfer-Encoding: chunked' . CRLF . CRLF .
	'1' . CRLF .
	'X' . CRLF .
	'9' . CRLF .
	'123456789' . CRLF .
	'0' . CRLF . CRLF
), qr/ 413 .*backend body:::/s, 'proxy chunked multi');

like(http(
	'POST /proxy HTTP/1.1' . CRLF .
	'Host: localhost' . CRLF .
	'Connection: close' . CRLF .
	'Transfer-Encoding: chunked' . CRLF . CRLF .
	'ffff' . CRLF .
	'0123456789'
), qr/ 413 .*backend body:::/s, 'proxy chunked long');

# error_page 400 with proxy_pass

# note that "chunked and length" test triggers 400 during parsing
# request headers, and therefore needs error_page at server level

like(http(
	'POST /proxy HTTP/1.1' . CRLF .
	'Host: localhost' . CRLF .
	'Connection: close' . CRLF .
	'Transfer-Encoding: chunked' . CRLF . CRLF .
	'1' . CRLF .
	'X' . CRLF .
	'X' . CRLF
), qr/ 400 .*backend body:::/s, 'proxy chunked bad');

like(http(
	'POST /proxy HTTP/1.1' . CRLF .
	'Host: localhost' . CRLF .
	'Connection: close' . CRLF .
	'Content-Length: 10' . CRLF .
	'Transfer-Encoding: chunked' . CRLF . CRLF .
	'0' . CRLF . CRLF
), qr/ 400 .*backend body:::/s, 'proxy chunked and length');

# error_page 502 after proxy with request buffering disabled

like(http(
	'GET /unbuf HTTP/1.0' . CRLF . CRLF
), qr/ 502 .*backend body:::/s, 'unbuf proxy');

like(http(
	'POST /unbuf HTTP/1.0' . CRLF .
	'Content-Length: 10' . CRLF . CRLF .
	'0',
	sleep => 0.1,
	body =>
	'123456789'
), qr/ 502 .*backend body:::/s, 'unbuf proxy small');

like(http(
	'POST /unbuf HTTP/1.0' . CRLF .
	'Content-Length: 10000' . CRLF . CRLF .
	'0123456789'
), qr/ 502 .*backend body:::/s, 'unbuf proxy long');

like(http(
	'POST /unbuf HTTP/1.1' . CRLF .
	'Host: localhost' . CRLF .
	'Connection: close' . CRLF .
	'Transfer-Encoding: chunked' . CRLF . CRLF,
	sleep => 0.1,
	body =>
	'a' . CRLF .
	'0123456789' . CRLF .
	'0' . CRLF . CRLF
), qr/ 502 .*backend body:::/s, 'unbuf proxy chunked');

like(http(
	'POST /unbuf HTTP/1.1' . CRLF .
	'Host: localhost' . CRLF .
	'Connection: close' . CRLF .
	'Transfer-Encoding: chunked' . CRLF . CRLF .
	'1' . CRLF .
	'X' . CRLF,
	sleep => 0.1,
	body =>
	'9' . CRLF .
	'123456789' . CRLF .
	'0' . CRLF . CRLF
), qr/ 502 .*backend body:::/s, 'unbuf proxy chunked multi');

like(http(
	'POST /unbuf HTTP/1.1' . CRLF .
	'Host: localhost' . CRLF .
	'Connection: close' . CRLF .
	'Transfer-Encoding: chunked' . CRLF . CRLF .
	'ffff' . CRLF .
	'0123456789'
), qr/ 502 .*backend body:::/s, 'unbuf proxy chunked long');

# error_page 413 and $content_length
# (used in fastcgi_pass, grpc_pass, uwsgi_pass)

like(http(
	'GET /length HTTP/1.0' . CRLF . CRLF
), qr/ 502 .*frontend body:::/s, '$content_length');

like(http(
	'POST /length HTTP/1.0' . CRLF .
	'Content-Length: 10' . CRLF . CRLF .
	'0123456789'
), qr/ 413 .*frontend body:::/s, '$content_length small');

like(http(
	'POST /length HTTP/1.0' . CRLF .
	'Content-Length: 10000' . CRLF . CRLF .
	'0123456789'
), qr/ 413 .*frontend body:::/s, '$content_length long');

like(http(
	'POST /length HTTP/1.1' . CRLF .
	'Host: localhost' . CRLF .
	'Connection: close' . CRLF .
	'Transfer-Encoding: chunked' . CRLF . CRLF .
	'a' . CRLF .
	'0123456789' . CRLF .
	'0' . CRLF . CRLF
), qr/ 413 .*frontend body:::/s, '$content_length chunked');

like(http(
	'POST /length HTTP/1.1' . CRLF .
	'Host: localhost' . CRLF .
	'Connection: close' . CRLF .
	'Transfer-Encoding: chunked' . CRLF . CRLF .
	'1' . CRLF .
	'X' . CRLF .
	'9' . CRLF .
	'123456789' . CRLF .
	'0' . CRLF . CRLF
), qr/ 413 .*frontend body:::/s, '$content_length chunked multi');

like(http(
	'POST /length HTTP/1.1' . CRLF .
	'Host: localhost' . CRLF .
	'Connection: close' . CRLF .
	'Transfer-Encoding: chunked' . CRLF . CRLF .
	'ffff' . CRLF .
	'0123456789'
), qr/ 413 .*frontend body:::/s, '$content_length chunked long');

###############################################################################
