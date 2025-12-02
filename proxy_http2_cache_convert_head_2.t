#!/usr/bin/perl

# (C) Zhidao HONG
# (C) Nginx, Inc.

# Tests for HTTP/2 proxy backend cache with proxy_cache_convert_head directive.

###############################################################################

use warnings;
use strict;

use Test::More;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/http proxy cache http_v2/)->plan(8)
	->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    proxy_cache_path   %%TESTDIR%%/cache  levels=1:2
                       keys_zone=NAME:1m;

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        proxy_cache   NAME;

        proxy_cache_key $request_uri;

        proxy_cache_valid   200 302  2s;

        add_header X-Cache-Status $upstream_cache_status;

        location / {
            proxy_pass http://127.0.0.1:8081/t.html;
            proxy_http_version 2;
            proxy_cache_convert_head   off;

            location /inner {
                proxy_pass http://127.0.0.1:8081/t.html;
                proxy_http_version 2;
                proxy_cache_convert_head on;
            }
        }

        location /on {
            proxy_pass http://127.0.0.1:8081/t.html;
            proxy_http_version 2;
            proxy_cache_convert_head on;
        }
    }

    server {
        listen       127.0.0.1:8081;
        server_name  localhost;

        http2 on;

        location / {
            root %%TESTDIR%%;
            add_header X-Method $request_method;
        }
    }
}

EOF

$t->write_file('t.html', 'SEE-THIS');
$t->run();

###############################################################################

like(http_get('/'), qr/x-method: GET/i, 'get');
like(http_head('/?2'), qr/x-method: HEAD/i, 'head');
like(http_head('/?2'), qr/HIT/, 'head cached');
unlike(http_get('/?2'), qr/SEE-THIS/, 'get after head');

like(http_get('/on'), qr/x-method: GET/i, 'on - get');
like(http_head('/on?2'), qr/x-method: GET/i, 'on - head');

like(http_get('/inner'), qr/x-method: GET/i, 'inner - get');
like(http_head('/inner?2'), qr/x-method: GET/i, 'inner - head');

###############################################################################
