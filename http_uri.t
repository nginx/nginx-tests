#!/usr/bin/perl

# (C) Sergey Kandaurov
# (C) Nginx, Inc.

# Tests for URI normalization.

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

my $t = Test::Nginx->new()->has(qw/http rewrite/)->plan(21)
	->write_file_expand('nginx.conf', <<'EOF')->run();

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
            add_header  X-URI          "x $uri x";
            add_header  X-Args         "y $args y";
            add_header  X-Request-URI  "z $request_uri z";
            return      204;
        }
    }
}

EOF

###############################################################################

like(http_get('/foo/bar%'), qr/400 Bad/, 'percent');
like(http_get('/foo/bar%1'), qr/400 Bad/, 'percent digit');

like(http_get('/foo/bar/.?args'), qr!x /foo/bar/ x!, 'dot args');
like(http_get('/foo/bar/.#frag'), qr!\AHTTP/1\.1 400 Bad!, 'frag 1');
like(http_get('/foo/bar/?#frag'), qr!\AHTTP/1\.1 400 Bad!, 'frag 2');
like(http_get('http://localhost:8080#frag'), qr!\AHTTP/1\.1 400 Bad!, 'frag 3');
like(http_get('http://localhost:8080?a#frag'), qr!\AHTTP/1\.1 400 Bad!, 'frag 4');
like(http_get('/%aa#frag'), qr!\AHTTP/1\.1 400 Bad!, 'frag 5');
like(http_get('/foo/bar/..?args'), qr!x /foo/ x!, 'dot dot args');
like(http_get('#frag'), qr!400 Bad!,
	'just fragment');
like(http_get('/foo/bar/.'), qr!x /foo/bar/ x!, 'trailing dot');
like(http_get('/foo/bar/..'), qr!x /foo/ x!, 'trailing dot dot');

like(http_get('http://localhost'), qr!x / x!, 'absolute');
like(http_get('http://localhost/'), qr!x / x!, 'absolute slash');
like(http_get('http://localhost?args'), qr!x / x.*y args y!ms,
	'absolute args');

like(http_get('http://localhost:8080'), qr!x / x!, 'port');
like(http_get('http://localhost:8080/'), qr!x / x!, 'port slash');
like(http_get('http://localhost:8080?args'), qr!x / x.*y args y!ms,
	'port args');

like(http_get('/ /'), qr/400 Bad/, 'space');
like(http_get("/\x02"), qr/400 Bad/, 'control');

like(http_get('/%02'), qr!x /\x02 x!, 'control escaped');

###############################################################################
