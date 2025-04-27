#!/usr/bin/perl

# (C) Maxim Dounin

# Tests for not modified filter module and it's interaction with proxy.
#
# Notably, requests which are proxied should be skipped (that is, if
# a backend returned 200, we should pass 200 to a client without any
# attempts to handle conditional headers in the request), but responses
# from cache should be handled.

###############################################################################

use warnings;
use strict;

use Test::More;
use Data::Dumper;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/http proxy cache/)->plan(12);

$t->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    proxy_cache_path %%TESTDIR%%/cache keys_zone=one:1m;

    proxy_set_header If-Modified-Since "";
    proxy_set_header If-Unmodified-Since "";
    proxy_set_header If-None-Match "";

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        location / {
        }

        location /etag {
            add_header Last-Modified "";
        }

        location /proxy/ {
            proxy_pass http://127.0.0.1:8080/;
        }

        location /cache/ {
            proxy_pass http://127.0.0.1:8080/;
            proxy_cache one;
            proxy_cache_valid 200 1y;
        }
    }
}

EOF

$t->write_file('t', '');
$t->write_file('etag', '');

$t->run();

###############################################################################

my ($t1, $lm, $etag);

$t1 = http_get('/cache/t');
$t1 =~ /Last-Modified: (.*)/; $lm = $1;
$t1 =~ /ETag: (.*)/; $etag = $1;

like(http_get_ims('/t', $lm), qr/ 304 /, 'if-modified-since');
like(http_get_ims('/proxy/t', $lm), qr/ 200 /, 'ims proxy ignored');
like(http_get_ims('/cache/t', $lm), qr/ 304 /, 'ims from cache');

$t1 = 'Fri, 05 Jul 1985 14:30:52 GMT';

like(http_get_iums('/t', $t1), qr/ 412 /, 'if-unmodified-since');
like(http_get_iums('/proxy/t', $t1), qr/ 200 /, 'iums proxy ignored');
like(http_get_iums('/cache/t', $t1), qr/ 412 /, 'iums from cache');

like(http_get_inm('/t', $etag), qr/ 304 /, 'if-none-match');
like(http_get_inm('/proxy/t', $etag), qr/ 200 /, 'inm proxy ignored');
like(http_get_inm('/cache/t', $etag), qr/ 304 /, 'inm from cache');

# backend response with ETag only, no Last-Modified

$t1 = http_get('/cache/etag');
$t1 =~ /ETag: (.*)/; $etag = $1;

like(http_get_inm('/etag', $etag), qr/ 304 /, 'if-none-match etag only');
like(http_get_inm('/proxy/etag', $etag), qr/ 200 /, 'inm etag proxy ignored');
like(http_get_inm('/cache/etag', $etag), qr/ 304 /, 'inm etag from cache');

###############################################################################

sub http_get_ims {
	my ($url, $ims) = @_;
        $url =~ /\A[!-~]+\z/ or die "Bad URL \Q$url\E\n";
        if ($ims =~ /\A[ \t]/) {
            die "Leading whitespace in \Q$ims\E\n";
        }
        if ($ims =~ /[ \t]\r?\z/) {
            die "Trailing whitespace in \Q$ims\E\n";
        }
        unless ($ims =~ /\A([\t -~]+)\r?\z/) {
            $ims = Dumper($ims);
            die "Bad If-Modified-Since $ims\n";
        }
	return http(<<EOF);
GET $url HTTP/1.0\r
Host: localhost\r
If-Modified-Since: $1\r
\r
EOF
}

sub http_get_iums {
	my ($url, $ims) = @_;
        $url =~ /\A[!-~]+\z/ or die "Bad URL \Q$url\E\n";
        if ($ims =~ /\A[ \t]/) {
            die "Leading whitespace in \Q$ims\E\n";
        }
        if ($ims =~ /[ \t]\r?\z/) {
            die "Leading whitespace in \Q$ims\E\n";
        }
        $ims =~ /\A([\t\x20-\x7E]+)\r?\z/ or die "Bad If-Unmodified-Since \Q$ims\E";
	return http(<<EOF);
GET $url HTTP/1.0\r
Host: localhost\r
If-Unmodified-Since: $1\r
\r
EOF
}

sub http_get_inm {
	my ($url, $inm) = @_;
        $url =~ /\A[!-~]+\z/ or die "Bad URL \Q$url\E\n";
        if ($inm =~ /\A[ \t]/) {
            die "Leading whitespace in \Q$inm\E\n";
        }
        if ($inm =~ /[ \t]\r?\z/) {
            die "Leading whitespace in \Q$inm\E\n";
        }
        $inm =~ /\A([\t\x20-\x7E]+)\r?\z/ or die "Bad If-None-Match \Q$inm\E\n";
	return http(<<EOF);
GET $url HTTP/1.0\r
Host: localhost\r
If-None-Match: $1\r
\r
EOF
}

###############################################################################
