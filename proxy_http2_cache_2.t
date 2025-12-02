#!/usr/bin/perl

# (C) Zhidao HONG
# (C) Nginx, Inc.

# Tests for HTTP/2 proxy backend with cache support.

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

my $t = Test::Nginx->new()->has(qw/http proxy cache http_v2/)
	->plan(15);

$t->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    proxy_cache_path   %%TESTDIR%%/cache  levels=1:2
                       keys_zone=NAME:1m;

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        location / {
            proxy_pass http://127.0.0.1:8081;
            proxy_http_version 2;

            proxy_cache   NAME;

            proxy_cache_valid   200 302  2s;
            proxy_cache_valid   301      1d;
            proxy_cache_valid   any      1m;

            proxy_cache_min_uses  1;

            proxy_cache_use_stale  error timeout invalid_header http_500
                                   http_404;

            proxy_no_cache  $arg_e;

            add_header X-Cache-Status $upstream_cache_status;
        }
    }

    server {
        listen       127.0.0.1:8081;
        server_name  localhost;

        http2 on;

        location / {
            root %%TESTDIR%%;
        }
    }
}

EOF

$t->write_file('t.html', 'SEE-THIS');
$t->write_file('t2.html', 'SEE-THIS');
$t->write_file('empty.html', '');
$t->write_file('big.html', 'x' x 1024);

$t->run();

###############################################################################

like(http_get('/t.html'), qr/SEE-THIS/, 'proxy request');

$t->write_file('t.html', 'NOOP');
like(http_get('/t.html'), qr/SEE-THIS/, 'proxy request cached');

unlike(http_head('/t2.html'), qr/SEE-THIS/, 'head request');
like(http_get('/t2.html'), qr/SEE-THIS/, 'get after head');
unlike(http_head('/t2.html'), qr/SEE-THIS/, 'head after get');

like(http_head('/empty.html?head'), qr/MISS/, 'empty head first');
like(http_head('/empty.html?head'), qr/HIT/, 'empty head second');

like(http_get_range('/t.html', 'Range: bytes=4-'), qr/^THIS/m, 'cached range');
like(http_get_range('/t.html', 'Range: bytes=0-2,4-'), qr/^SEE.*^THIS/ms,
	'cached multipart range');

like(http_get('/empty.html'), qr/MISS/, 'empty get first');
like(http_get('/empty.html'), qr/HIT/, 'empty get second');

select(undef, undef, undef, 3.1);
unlink $t->testdir() . '/t.html';
like(http_get('/t.html'), qr/STALE/, 'non-empty get stale');

unlink $t->testdir() . '/empty.html';
like(http_get('/empty.html'), qr/STALE/, 'empty get stale');

# no client connection close with response on non-cacheable HEAD requests

my $s = http(<<EOF, start => 1);
HEAD /big.html?e=1 HTTP/1.1
Host: localhost

EOF

my $r = http_get('/t.html', socket => $s);

like($r, qr/Connection: keep-alive/, 'non-cacheable head - keepalive');
like($r, qr/SEE-THIS/, 'non-cacheable head - second');

###############################################################################

sub http_get_range {
	my ($url, $extra) = @_;
	return http(<<EOF);
GET $url HTTP/1.1
Host: localhost
Connection: close
$extra

EOF
}

###############################################################################
