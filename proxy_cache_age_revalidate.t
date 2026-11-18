#!/usr/bin/perl

# (C) Andrei Chmelev

# Tests for proxy cache Age header handling during revalidation.

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

my $t = Test::Nginx->new()->has(qw/http proxy cache map/)->plan(86)
	->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    proxy_cache_path %%TESTDIR%%/cache keys_zone=NAME:1m;
    proxy_cache_key $request_uri;

    map $http_if_modified_since $age {
        ""      99;
        default $arg_age;
    }

    map $arg_no_cc $revalidated_control {
        default max-age=100;
        1       "";
    }

    map $http_if_modified_since $cache_control {
        ""      max-age=100;
        default $revalidated_control;
    }

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        proxy_cache NAME;
        proxy_cache_revalidate on;
        proxy_cache_valid 200 1m;

        add_header X-Cache-Status $upstream_cache_status;
        add_header Age $upstream_cache_age;

        location / {
            proxy_pass http://127.0.0.1:8081;
        }

        location /hide/ {
            proxy_pass http://127.0.0.1:8081/;
            proxy_hide_header Age;
        }
    }

    server {
        listen       127.0.0.1:8081;
        server_name  localhost;

        location / {
            add_header Cache-Control $cache_control;
            add_header Age $age;
        }

        location /before/ {
            alias %%TESTDIR%%/;
            add_header Age $age;
            add_header Cache-Control $cache_control;
        }
    }
}

EOF

$t->write_file('t', 'SEE-THIS');
$t->run();

###############################################################################

my @tests = (
	[ '/t?age=1',                  1,   'HIT',         'fresh' ],
	[ '/before/t?age=1',           1,   'HIT',         'fresh age first' ],
	[ '/t?age=200',                200, 'REVALIDATED', 'stale' ],
	[ '/before/t?age=200',         200, 'REVALIDATED', 'stale age first' ],
	[ '/t?age=100',                100, 'REVALIDATED', 'equal' ],
	[ '/before/t?age=100',         100, 'REVALIDATED', 'equal age first' ],
	[ '/t?age=',                   0,   'HIT',         'no age' ],
	[ '/hide/t?age=1',             1,   'HIT',         'hidden age' ],
	[ '/t?age=1&no_cc=1',          1,   'HIT',         'no cache-control' ],
	[ '/t?age=200&no_cc=1',        200, 'REVALIDATED', 'stale no cc' ],
	[ '/before/t?age=200&no_cc=1', 200, 'REVALIDATED', 'stale no cc first' ],
);

for my $test (@tests) {
	my ($uri, $age, $status, $name) = @$test;
	like(http_get($uri), qr/X-Cache-Status: MISS/, "$name cached");
	like(http_get($uri), qr/X-Cache-Status: HIT/, "$name cache hit");
}

sleep 2;

for my $test (@tests) {
	my ($uri, $age, $status, $name) = @$test;
	my $r = http_get($uri);
	like($r, qr/X-Cache-Status: REVALIDATED/, "$name revalidated");
	like($r, qr/^Age: $age\x0d?$/m, "$name revalidated age");

	$r = http_get($uri);
	like($r, qr/X-Cache-Status: $status/, "$name next request");
	my ($n) = $r =~ /^Age: (\d+)/m;
	ok(defined $n && $n >= $age && $n <= $age + 1,
		"$name next request age");
}

# The new age must survive both time spent in cache and a process restart.

sleep 2;

for my $test (grep { $_->[2] eq 'HIT' } @tests) {
	my ($uri, $age, $status, $name) = @$test;
	my $r = http_get($uri);
	like($r, qr/X-Cache-Status: HIT/, "$name remains fresh");
	my ($n) = $r =~ /^Age: (\d+)/m;
	ok(defined $n && $n >= $age + 2 && $n <= $age + 5,
		"$name age increased");
}

$t->stop()->run();

for my $test (grep { $_->[2] eq 'HIT' } @tests) {
	my ($uri, $age, $status, $name) = @$test;
	my $r = http_get($uri);
	like($r, qr/X-Cache-Status: HIT/, "$name cached after restart");
	my ($n) = $r =~ /^Age: (\d+)/m;
	ok(defined $n && $n >= $age + 2 && $n <= $age + 6,
		"$name age after restart");
}

###############################################################################
