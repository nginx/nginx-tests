#!/usr/bin/perl

# (C) Maxim Dounin
# (C) Nginx, Inc.

# Tests for http proxy module, proxy_next_upstream directive.

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

my $t = Test::Nginx->new()->has(qw/http proxy rewrite/);

$t->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    upstream u {
        server 127.0.0.1:8081;
        server 127.0.0.1:8082;
    }

    upstream u2 {
        server 127.0.0.1:8081;
        server 127.0.0.1:8082;
    }

    upstream u3 {
        server 127.0.0.1:8081;
        server 127.0.0.1:8082 down;
    }

    upstream u4 {
        server 127.0.0.1:8081;
    }

    upstream u5 {
        server 127.0.0.1:8083;
        server 127.0.0.1:8084;
    }

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        location / {
            proxy_pass http://u;
            proxy_next_upstream http_500 http_404;
        }

        location /all/ {
            proxy_pass http://u2;
            proxy_next_upstream http_500 http_404;
            error_page 404 /all/404;
            proxy_intercept_errors on;
        }

        location /all/404 {
            return 200 "$upstream_addr\n";
        }

        location /down {
            proxy_pass http://u3;
            proxy_next_upstream http_404;
        }

        # no_live reinitializes peer selection once every peer has been
        # tried, so that retries continue up to proxy_next_upstream_tries

        location = /no_live {
            proxy_pass http://u2/all/;
            proxy_next_upstream http_404 no_live;
            proxy_next_upstream_tries 3;
            proxy_intercept_errors on;
            error_page 404 = /no_live/status;
        }

        # a single server, retried more times than there are servers

        location = /no_live/single {
            proxy_pass http://u4/all/;
            proxy_next_upstream http_404 no_live;
            proxy_next_upstream_tries 3;
            proxy_intercept_errors on;
            error_page 404 = /no_live/addr;
        }

        # an upstream created from an address rather than an upstream block

        location = /no_live/resolved {
            set $back 127.0.0.1:%%PORT_8081%%;
            proxy_pass http://$back/all/;
            proxy_next_upstream http_404 no_live;
            proxy_next_upstream_tries 3;
            proxy_intercept_errors on;
            error_page 404 = /no_live/status;
        }

        # without proxy_next_upstream_tries there is nothing to retry up to,
        # and peers are tried once

        location = /no_live/unlimited {
            proxy_pass http://u2/all/;
            proxy_next_upstream http_404 no_live;
            proxy_intercept_errors on;
            error_page 404 = /no_live/status;
        }

        # peers disabled by max_fails are retried as well

        location = /no_live/dead {
            proxy_pass http://u5;
            proxy_next_upstream error no_live;
            proxy_next_upstream_tries 4;
            proxy_intercept_errors on;
            error_page 502 = /no_live/status;
        }

        location = /no_live/status {
            return 200 "x${upstream_status}x";
        }

        location = /no_live/addr {
            return 200 "x${upstream_addr}x";
        }

        # each upstream request has its own proxy_next_upstream_tries budget

        location = /chain {
            proxy_pass http://u2/all/;
            proxy_next_upstream http_404;
            proxy_next_upstream_tries 2;
            proxy_intercept_errors on;
            error_page 404 = /chain/second;
        }

        location = /chain/second {
            proxy_pass http://u2/all/;
            proxy_next_upstream http_404;
            proxy_next_upstream_tries 2;
            add_header X-Upstream-Status "x${upstream_status}x" always;
        }
    }

    server {
        listen       127.0.0.1:8081;
        server_name  localhost;

        location / {
            return 404;
        }
        location /ok {
            return 200 "AND-THIS\n";
        }
        location /500 {
            return 500;
        }

        location /all/ {
            return 404;
        }
    }

    server {
        listen       127.0.0.1:8082;
        server_name  localhost;

        location / {
            return 200 "TEST-OK-IF-YOU-SEE-THIS\n";
        }

        location /all/ {
            return 404;
        }
    }
}

EOF

$t->try_run('no no_live')->plan(14);

###############################################################################

my ($p1, $p2) = (port(8081), port(8082));

# check if both request fallback to a backend
# which returns valid response

like(http_get('/'), qr/SEE-THIS/, 'proxy request');
like(http_get('/'), qr/SEE-THIS/, 'second request');

# make sure backend isn't switched off after
# proxy_next_upstream http_404

like(http_get('/ok') . http_get('/ok'), qr/AND-THIS/, 'not down');

# next upstream on http_500

like(http_get('/500'), qr/SEE-THIS/, 'request 500');
like(http_get('/500'), qr/SEE-THIS/, 'request 500 second');

# make sure backend switched off with http_500

unlike(http_get('/ok') . http_get('/ok'), qr/AND-THIS/, 'down after 500');

# make sure all backends are tried once

like(http_get('/all/rr'),
	qr/^127.0.0.1:($p1, 127.0.0.1:$p2|$p2, 127.0.0.1:$p1)$/mi,
	'all tried once');

# make sure backend marked as down doesn't count towards "no live upstreams"
# after all backends are tried with http_404

like(http_get('/down/'), qr/Not Found/, 'all tried with down');

# make sure peers are tried again once all of them have been tried

like(http_get('/no_live'), qr/x404, 404, 404x/, 'no_live');
like(http_get('/no_live/single'),
	qr/x127.0.0.1:$p1, 127.0.0.1:$p1, 127.0.0.1:${p1}x/,
	'no_live single server');
like(http_get('/no_live/resolved'), qr/x404, 404, 404x/, 'no_live resolved');

# make sure no_live alone does not change anything

like(http_get('/no_live/unlimited'), qr/x404, 404x/, 'no_live no tries');

# make sure peers disabled by max_fails are retried as well

like(http_get('/no_live/dead'), qr/x502, 502, 502, 502x/, 'no_live no live');

# make sure a second upstream request in the same request is not limited
# by the attempts for the first one

like(http_get('/chain'), qr/x404, 404 : 404, 404x/,
	'tries per upstream request');

###############################################################################
