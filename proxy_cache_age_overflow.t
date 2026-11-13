#!/usr/bin/perl

# (C) Andrei Chmelev

# Tests for overflowing upstream Age values.

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

my $t = Test::Nginx->new()->has(qw/http proxy cache map/)
	->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    proxy_cache_path %%TESTDIR%%/cache keys_zone=NAME:1m;
    proxy_cache_key $request_uri;

    map "$arg_revalidate:$http_if_modified_since" $age {
        "1:"    99;
        default $arg_age;
    }

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        proxy_cache NAME;
        proxy_cache_revalidate on;
        add_header X-Cache-Status $upstream_cache_status;
        add_header Age $upstream_cache_age;

        location / {
            proxy_pass http://127.0.0.1:8081;
        }

        location /ignore/ {
            proxy_pass http://127.0.0.1:8081/;
            proxy_ignore_headers Age;
        }
    }

    server {
        listen       127.0.0.1:8081;
        server_name  localhost;

        location / {
            add_header Cache-Control max-age=100;
            add_header Age $age;
            add_header X-Accel-Expires $arg_accel;
        }

        location /before/ {
            alias %%TESTDIR%%/;
            add_header Age $age;
            add_header Cache-Control max-age=100;
        }
    }
}

EOF

# Accept either nginx integer width, independently of Perl's integer size.

my $max = '(?:2147483647|9223372036854775807)';
my $large = '9' x 256;
my @tests = (
	[ '2147483647', '2147483647', 1, '32-bit maximum' ],
	[ '2147483648', '(?:2147483647|2147483648)', 1, '32-bit overflow' ],
	[ '9223372036854775807', $max, 1, '64-bit maximum' ],
	[ '9223372036854775808', $max, 1, '64-bit overflow' ],
	[ $large, $max, 1, 'long overflow' ],
	[ $large . 'x', '0', 0, 'invalid suffix after overflow' ],
	[ $large . ',1', '0', 0, 'comma after overflow' ],
	[ '-1', '0', 0, 'negative' ],
	[ '1;2', '0', 0, 'semicolon' ],
	[ ('0' x 256), '0', 0, 'leading zeros' ],
);

$t->write_file('t', 'SEE-THIS');
$t->run()->plan(12 * scalar(@tests) + 6);

###############################################################################

for my $prefix ('/t', '/before/t') {
	for my $test (@tests) {
		my ($age, $expected, $stale, $name) = @$test;
		my $uri = "$prefix?age=$age";
		my $status = $stale ? 'MISS' : 'HIT';
		like(get($uri), qr/X-Cache-Status: $status/,
			"$prefix $name cache status");
		like(get("$uri&revalidate=1"), qr/X-Cache-Status: HIT/,
			"$prefix $name revalidation cached");
	}
}

like(get("/ignore/t?age=$large"), qr/X-Cache-Status: HIT/,
	'overflow ignored');

my $saturated = "/t?age=$large&accel=100";
my $r = get($saturated);
like($r, qr/X-Cache-Status: HIT/, 'overflow with x-accel-expires cached');
like($r, qr/^Age: $max\x0d?$/m, 'cached age saturated');

sleep 2;

for my $prefix ('/t', '/before/t') {
	for my $test (@tests) {
		my ($age, $expected, $stale, $name) = @$test;
		my $uri = "$prefix?age=$age&revalidate=1";
		my $r = http_get($uri);
		like($r, qr/X-Cache-Status: REVALIDATED/,
			"$prefix $name revalidated");
		like($r, qr/^Age: $expected\x0d?$/m,
			"$prefix $name revalidated age");

		$r = http_get($uri);
		my $status = $stale ? 'REVALIDATED' : 'HIT';
		like($r, qr/X-Cache-Status: $status/,
			"$prefix $name next request");
		my $next = $stale ? $expected : '[0-1]';
		like($r, qr/^Age: $next\x0d?$/m,
			"$prefix $name next request age");
	}
}

$r = http_get($saturated);
like($r, qr/X-Cache-Status: HIT/, 'saturated age remains cached');
like($r, qr/^Age: $max\x0d?$/m, 'age sum saturated');
unlike($r, qr/^Age: -/m, 'age did not wrap');

###############################################################################

sub get {
	my ($uri) = @_;
	http_get($uri);
	http_get($uri);
}

###############################################################################
