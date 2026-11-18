#!/usr/bin/perl

# (C) Vadim Zhestikov
# (C) Nginx, Inc.

# Tests for http proxy cache, cache bypass with intercepted errors.

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

my $t = Test::Nginx->new()->has(qw/http proxy cache rewrite/)->plan(2);

$t->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    proxy_cache_path %%TESTDIR%%/cache keys_zone=NAME:32k;

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        proxy_cache NAME;
        proxy_cache_valid 200 1m;
        proxy_cache_bypass $arg_bypass;

        proxy_intercept_errors on;
        error_page 502 = /intercepted;

        add_header X-Cache-Status $upstream_cache_status;

        location / {
            proxy_pass http://127.0.0.1:8081;
        }

        location = /intercepted {
            return 200 "intercepted\n";
        }
    }

    server {
        listen       127.0.0.1:8081;
        server_name  localhost;

        location / {
            return 502;
        }

        location = /ok {
            return 200 "ok\n";
        }
    }
}

EOF

$t->run();

###############################################################################

# with cache bypass, an intercepted error which is not cached must not leave
# a cache node referenced, or the keys zone runs out of nodes

http_get("/e$_?bypass=1") for 1 .. 300;

like(http_get('/ok'), qr/^HTTP\/1.1 200 .*MISS/s, 'cache after bypass');
like(http_get('/ok'), qr/^HTTP\/1.1 200 .*HIT/s, 'cache after bypass cached');

###############################################################################
