#!/usr/bin/perl

# (C) Gabriel Clima
# (C) Gcore

# Tests for slice filter with a slice subrequest redirected to a named
# location.  The redirect used to leave the subrequest without a slice
# context: $slice_range evaluated to an empty value, the re-proxied
# request went upstream without a Range header, and the complete
# response was appended to the parent response and cached under a
# sliceless key.

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

my $t = Test::Nginx->new()->has(qw/http proxy cache slice rewrite/)
	->plan(9);

$t->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    proxy_cache_path   %%TESTDIR%%/cache  keys_zone=NAME:1m;
    proxy_cache_key    $uri$is_args$args$slice_range;

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        location /cache/ {
            slice 2;

            proxy_pass    http://127.0.0.1:8081/;

            proxy_cache   NAME;

            proxy_set_header   Range  $slice_range;

            proxy_cache_valid   200 206  1h;

            proxy_intercept_errors  on;
            error_page  302 = @redirect;

            add_header X-Cache-Status $upstream_cache_status;
        }

        location @redirect {
            slice 2;

            set $location  $upstream_http_location;

            proxy_pass    $location;

            proxy_cache   NAME;

            proxy_set_header   Range  $slice_range;

            proxy_cache_valid   200 206  1h;
        }
    }

    server {
        listen       127.0.0.1:8081;
        server_name  localhost;

        location / {
            if ($http_range = "bytes=2-3") {
                return 302 http://127.0.0.1:8081/moved$uri;
            }
        }

        location /moved/ {
            alias %%TESTDIR%%/;
        }
    }
}

EOF

$t->write_file('t', '0123456789abcdef');
$t->run();

###############################################################################

my $r;

# the second slice is redirected into the named location; the restored
# context keeps $slice_range intact for the re-proxied request

$r = get('/cache/t');
like($r, qr/ 200 /, 'redirected slice - status');
like($r, qr/^0123456789abcdef$/m, 'redirected slice - body');

# the redirected slice is cached under the same key as a normal slice,
# not under a sliceless key with a complete response

is(scalar @{[ glob $t->testdir() . '/cache/*' ]}, 8,
	'redirected slice - cache entries');

$r = get('/cache/t', 'Range: bytes=2-3');
like($r, qr/ 206 /, 'redirected slice cached - status');
like($r, qr/^23$/m, 'redirected slice cached - body');
like($r, qr/X-Cache-Status: HIT/, 'redirected slice cached - cache status');

$r = get('/cache/t');
like($r, qr/ 200 /, 'cached - status');
like($r, qr/^0123456789abcdef$/m, 'cached - body');

$t->stop();

unlike($t->read_file('error.log'), qr/missing slice response/,
	'no missing slice response');

###############################################################################

sub get {
	my ($url, $extra) = @_;
	$extra = '' unless defined $extra;
	return http(<<EOF);
GET $url HTTP/1.1
Host: localhost
Connection: close
$extra

EOF
}

###############################################################################
