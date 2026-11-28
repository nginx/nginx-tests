#!/usr/bin/perl

# (C) Jiří Setnička
# (C) Nginx, Inc.

# Tests for slice filter with gunzip filter.

###############################################################################

use warnings;
use strict;

use Test::More;

use Digest::MD5 qw/ md5_hex /;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx qw/ :DEFAULT :gzip http_content /;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

eval { require IO::Compress::Gzip; };
plan(skip_all => "IO::Compress::Gzip not found") if $@;

my $t = Test::Nginx->new()->has(qw/http proxy cache slice gunzip/)
	->plan(14);

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

        slice 128k;

        gunzip on;
        gunzip_buffers 2 4k;

        location /proxy/ {
            proxy_pass    http://127.0.0.1:8081/;

            proxy_set_header   Range  $slice_range;
        }

        location /cache/ {
            proxy_pass    http://127.0.0.1:8081/;

            proxy_cache   NAME;

            proxy_set_header   Range  $slice_range;

            proxy_cache_valid   200 206  1h;

            add_header X-Cache-Status $upstream_cache_status;
        }
    }

    server {
        listen       127.0.0.1:8081;
        server_name  localhost;

        location / {
            add_header Content-Encoding gzip;
        }
    }
}

EOF

# compressible data with back-references across slice boundaries

srand(1);
my $in = join('', map { (qw/A C G T/)[int(rand(4))] } (1 .. 1200000));
my $out;

IO::Compress::Gzip::gzip(\$in => \$out);

$t->write_file('t.gz', $out);
$t->run();

###############################################################################

my $plain = http_get('/proxy/t.gz');
my $gzip = http_gzip_request('/proxy/t.gz');
my $range = get('/proxy/t.gz', 'Range: bytes=100-199');

my $miss = http_get('/cache/t.gz');
my $hit = http_get('/cache/t.gz');
my $hit_gzip = http_gzip_request('/cache/t.gz');
my $hit_range = get('/cache/t.gz', 'Range: bytes=100-199');

$t->stop();

unlike($plain, qr/Content-Encoding/, 'no content encoding');
like($gzip, qr/Content-Encoding: gzip/, 'gzip - content encoding');
like($range, qr/ 200 /, 'range - no partial content');
like($miss, qr/X-Cache-Status: MISS/, 'cache - miss');
like($hit, qr/X-Cache-Status: HIT/, 'cache - hit');
like($hit_gzip, qr/Content-Encoding: gzip/, 'cache - gzip content encoding');

TODO: {
local $TODO = 'not yet' unless $t->has_version('1.31.10');

is(md5_hex(http_content($plain)), md5_hex($in), 'gunzipped');
is(md5_hex(http_content($gzip)), md5_hex($out), 'gzip - compressed');
is(md5_hex(http_content($range)), md5_hex($in), 'range - gunzipped');
is(md5_hex(http_content($miss)), md5_hex($in), 'cache - miss gunzipped');
is(md5_hex(http_content($hit)), md5_hex($in), 'cache - hit gunzipped');
is(md5_hex(http_content($hit_gzip)), md5_hex($out),
	'cache - gzip compressed');
is(md5_hex(http_content($hit_range)), md5_hex($in),
	'cache - range gunzipped');

unlike($t->read_file('error.log'), qr/\[error\]/, 'no errors');

}

###############################################################################

sub get {
	my ($url, $extra) = @_;
	return http(<<EOF);
GET $url HTTP/1.1
Host: localhost
Connection: close
$extra

EOF
}

###############################################################################
