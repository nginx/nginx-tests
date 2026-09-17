#!/usr/bin/perl

# (C) Maxim Dounin

# Tests for not modified filter module.

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

my $t = Test::Nginx->new()->has(qw/http proxy cache/)->plan(17)
	->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    proxy_cache_path	%%TESTDIR%%/cache	levels=1:2
			keys_zone=test:1m;

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        location / {
            if_modified_since before;
        }

        location /w {
            proxy_pass http://127.0.0.1:8081/;
            proxy_cache test;
            proxy_cache_valid 200 1h;
            proxy_cache_bypass 1;
            proxy_set_header If-Match "";
            proxy_set_header If-None-Match "";
        }
    }

    server {
        listen       127.0.0.1:8081;
        server_name  localhost;

        location / {
            etag off;
            add_header ETag "W/\"weaktag\"";
            return 200 "";
        }
    }
}

EOF

$t->write_file('t', '');
$t->write_file('w', '');

$t->run();

###############################################################################

like(http_get_ims('/t', 'Wed, 08 Jul 2037 22:53:52 GMT'), qr/ 304 /,
	'0x7F000000');
like(http_get_ims('/t', 'Tue, 19 Jan 2038 03:14:07 GMT'), qr/ 304 /,
	'0x7FFFFFFF');

SKIP: {
	skip "only for 32-bit time_t", 2 if (gmtime(0xFFFFFFFF))[5] == 206;

	like(http_get_ims('/t', 'Tue, 19 Jan 2038 03:14:08 GMT'), qr/ 200 /,
		'0x7FFFFFFF + 1');
	like(http_get_ims('/t', 'Fri, 25 Feb 2174 09:42:23 GMT'), qr/ 200 /,
		'0x17FFFFFFF');
}

# If-Match, If-None-Match tests

my ($t1, $etag);

$t1 = http_get('/t');
$t1 =~ /ETag: (".*")/;
$etag = $1;

like(http_get_inm('/t', $etag), qr/ 304 /, 'if-none-match');
like(http_get_inm('/t', '"foo"'), qr/ 200 /, 'if-none-match fail');
like(http_get_inm('/t', '"foo", "bar", ' . $etag . ' , "baz"'), qr/ 304 /,
	'if-none-match with complex list');
like(http_get_inm('/t', '*'), qr/ 304 /, 'if-none-match all');
like(http_get_inm('/t', 'W/' . $etag), qr/ 304 /, 'if-none-match weak');
like(http_get_im('/t', $etag), qr/ 200 /, 'if-match');
like(http_get_im('/t', '"foo"'), qr/ 412 /, 'if-match fail');
like(http_get_im('/t', '"foo", "bar", ' . "\t" . $etag . ' , "baz"'),
	qr/ 200 /, 'if-match with complex list');
like(http_get_im('/t', '*'), qr/ 200 /, 'if-match all');
like(http_get_im('/t', 'W/' . $etag), qr/ 412 /, 'if-match weak fail');

# server MUST ignore precondition if its response wouldn't be 2xx or 412

like(http_get_im('/nx', '"foo"'), qr/ 404 /, 'if-match ignored with 404');

# RFC 9110, 8.8.3.2: strong comparison treats a weak entity-tag as never
# matching, so If-Match against a weak server ETag always fails, even if
# the opaque-tags are byte-identical.

like(http_get_im('/w', 'W/"weaktag"'), qr/ 412 /,
	'if-match weak server etag fail');
like(http_get_im('/w', '"weaktag"'), qr/ 412 /,
	'if-match strong client against weak server fail');

###############################################################################

sub http_get_ims {
	my ($url, $ims) = @_;
	return http(<<EOF);
GET $url HTTP/1.0
Host: localhost
If-Modified-Since: $ims

EOF
}

sub http_get_inm {
	my ($url, $inm) = @_;
	return http(<<EOF);
GET $url HTTP/1.0
Host: localhost
If-None-Match: $inm

EOF
}

sub http_get_im {
	my ($url, $inm) = @_;
	return http(<<EOF);
GET $url HTTP/1.0
Host: localhost
If-Match: $inm

EOF
}

###############################################################################
