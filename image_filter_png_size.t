#!/usr/bin/perl

# (C) Nginx, Inc.

# Tests for image filter, PNG images with dimensions above 16 bits.

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

my $t = Test::Nginx->new()->has(qw/http image_filter/)->plan(7)
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

        location /resize/ {
            image_filter resize 50 50;
            alias %%TESTDIR%%/;
        }

        location /rotate/ {
            image_filter rotate 90;
            alias %%TESTDIR%%/;
        }

        location /size/ {
            image_filter size;
            alias %%TESTDIR%%/;
        }
    }
}

EOF

# PNG stores width and height in 32-bit fields; dimensions that do not
# fit into 16 bits are not expected and should be rejected, rather than
# understated by reading only the low 16 bits

$t->write_file('max.png', png(65535, 2));
$t->write_file('wide.png', png(65536, 2));
$t->write_file('tall.png', png(2, 65536));

$t->run();

###############################################################################

like(http_get('/resize/max.png'), qr/200 OK/, 'resize 16-bit width');

TODO: {
local $TODO = 'not yet' unless $t->has_version('1.31.6');

like(http_get('/resize/wide.png'), qr/ 415 /, 'resize wide');
like(http_get('/resize/tall.png'), qr/ 415 /, 'resize tall');
like(http_get('/rotate/wide.png'), qr/ 415 /, 'rotate wide');
like(http_get('/rotate/tall.png'), qr/ 415 /, 'rotate tall');
like(http_get('/size/wide.png'), qr/\{\}/, 'size wide');

}

like(http_get('/size/max.png'), qr/"width": 65535/, 'size 16-bit width');

###############################################################################

sub png {
	my ($width, $height) = @_;

	my $im = new GD::Image($width, $height);
	$im->colorAllocate(255, 255, 255);

	return $im->png;
}

###############################################################################
