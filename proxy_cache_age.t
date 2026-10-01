#!/usr/bin/perl

# (C) Maxim Dounin

# Tests for proxy cache Age header handling.

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

my $t = Test::Nginx->new()->has(qw/http proxy cache/)
	->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    proxy_cache_path %%TESTDIR%%/cache keys_zone=NAME:1m;
    proxy_cache_key $request_uri;

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        add_header  X-Cache-Status  $upstream_cache_status;
        add_header  Age  $upstream_cache_age;

        location / {
            proxy_pass  http://127.0.0.1:8081;
            proxy_cache NAME;
        }

        location /revalidate {
            proxy_pass  http://127.0.0.1:8081;
            proxy_cache NAME;
            proxy_cache_revalidate on;
        }

        location /ignore/ {
            proxy_pass  http://127.0.0.1:8081/;
            proxy_cache NAME;

            proxy_ignore_headers Age;
        }
    }

    server {
        listen       127.0.0.1:8081;
        server_name  localhost;

        location /fresh {
            add_header Cache-Control max-age=100;
            add_header Age 90;
        }

        location /stale {
            add_header Cache-Control max-age=100;
            add_header Age 110;
        }

        location /before {
            add_header Age 110;
            add_header Cache-Control max-age=100;
        }

        location /noage {
            add_header Cache-Control max-age=100;
        }

        location /revalidate {
            add_header Cache-Control max-age=1;
        }
    }
}

EOF

$t->write_file('fresh', 'SEE-THIS');
$t->write_file('stale', 'SEE-THIS');
$t->write_file('before', 'SEE-THIS');
$t->write_file('noage', 'SEE-THIS');
$t->write_file('revalidate', 'SEE-THIS');

$t->try_run('no age support')->plan(13);

###############################################################################

# responses with Age header cached

like(get('/fresh'), qr/HIT/, 'fresh cached');
like(get('/stale'), qr/MISS/, 'stale not cached');
like(get('/before'), qr/MISS/, 'stale age first not cached');
like(get('/noage'), qr/HIT/, 'noage cached');
like(get('/revalidate'), qr/HIT/, 'revalidate cached');

# the same with the Age header ignored

like(get('/ignore/fresh'), qr/HIT/, 'fresh ignore');
like(get('/ignore/stale'), qr/HIT/, 'stale ignore');
like(get('/ignore/before'), qr/HIT/, 'stale age first ignore');
like(get('/ignore/noage'), qr/HIT/, 'noage ignore');

# age header updated on cached responses

sleep(2);

like(http_get('/fresh'), qr/^(?>.*?Age:) 9[1-5](?!.*Age:)/s,
	'cached age updated');
like(http_get('/stale'), qr/^(?>.*?Age:) 110(?!.*Age:)/s,
	'not cached age preserved');
like(http_get('/noage'), qr/^(?>.*?Age:) [1-5](?!.*Age:)/s,
	'noage age added');

like(http_get('/revalidate'), qr/REVALIDATED(?!.*Age:)/ms,
	'revalidate age not added');

###############################################################################

sub get {
	my ($uri) = @_;
	http_get($uri);
	http_get($uri);
}

###############################################################################
