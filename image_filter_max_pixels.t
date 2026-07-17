#!/usr/bin/perl

# (C) Nginx, Inc.

# Tests for the image_filter_max_pixels directive.

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

eval { require GD; };
plan(skip_all => 'GD not installed') if $@;

my $t = Test::Nginx->new()->has(qw/http image_filter/)
	->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        location /allow {
            image_filter resize 50 50;
            image_filter_max_pixels 40000;
            alias %%TESTDIR%%/;
        }

        location /deny {
            image_filter resize 50 50;
            image_filter_max_pixels 5000;
            alias %%TESTDIR%%/;
        }

        location /off {
            image_filter resize 50 50;
            image_filter_max_pixels 0;
            alias %%TESTDIR%%/;
        }
    }
}

EOF

# a 100x100 (10000 pixel) source image

my $im = new GD::Image(100, 100);
my $white = $im->colorAllocate(255, 255, 255);
my $black = $im->colorAllocate(0, 0, 0);
$im->rectangle(0, 0, 99, 99, $black);
$t->write_file('img.png', $im->png);

# a source whose true width exceeds 16 bits (65540 x 2 = 131080 pixels).
# PNG stores width and height in 32-bit fields; reading only their low 16
# bits would understate 65540 as 4 and let the 131080-pixel canvas slip past
# the limit.

my $wide = new GD::Image(65540, 2);
$wide->colorAllocate(255, 255, 255);
$t->write_file('wide.png', $wide->png);

$t->try_run('no image_filter_max_pixels')->plan(4);

###############################################################################

# source pixels below the limit are processed

like(http_get('/allow/img.png'), qr/200 OK/, 'below limit');

# source pixels above the limit are rejected

like(http_get('/deny/img.png'), qr/ 415 /, 'above limit');

# zero disables the limit

like(http_get('/off/img.png'), qr/200 OK/, 'limit disabled');

# a source whose true dimensions exceed 16 bits must be measured in full,
# not understated by reading only the low 16 bits of the PNG size fields

like(http_get('/deny/wide.png'), qr/ 415 /, 'wide source above limit');

###############################################################################
