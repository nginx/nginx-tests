#!/usr/bin/perl

# (C) Nginx, Inc.

# Tests for QUERY method.

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

my $t = Test::Nginx->new()->has(qw/http access proxy cache rewrite/)->plan(6)
	->write_file_expand('nginx.conf', <<'EOF')->run();

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    proxy_cache_path %%TESTDIR%%/cache keys_zone=NAME:1m;

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        location /method {
            return 200 $request_method;
        }

        location /limit {
            limit_except QUERY {
                deny all;
            }

            proxy_pass http://127.0.0.1:8081;
        }

        location /cache {
            proxy_pass http://127.0.0.1:8081;

            proxy_cache NAME;
            proxy_cache_methods QUERY;
            proxy_cache_valid 1m;

            add_header X-Cache-Status $upstream_cache_status;
        }
    }

    server {
        listen       127.0.0.1:8081;
        server_name  localhost;

        return 200 $request_method;
    }
}

EOF

###############################################################################

like(query('/method'), qr/^QUERY$/m, 'query method');
like(query('/limit'), qr/ 200 /, 'query limit except');
like(http_get('/limit'), qr/ 403 /, 'get limit except');
like(method('OTHER', '/limit'), qr/ 403 /, 'unknown limit except');
like(query('/cache'), qr/X-Cache-Status: MISS/, 'query cache miss');
like(query('/cache'), qr/X-Cache-Status: HIT/, 'query cache hit');

###############################################################################

sub query {
	my ($uri) = @_;
	return method('QUERY', $uri);
}

sub method {
	my ($method, $uri) = @_;
	return http(<<EOF);
$method $uri HTTP/1.1
Host: localhost
Connection: close

EOF
}

###############################################################################
