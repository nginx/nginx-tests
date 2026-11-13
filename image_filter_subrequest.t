#!/usr/bin/perl

# (C) Nginx, Inc.

# Tests for image filter module in subrequests.

###############################################################################

use warnings;
use strict;

use Test::More;

use Socket qw/CRLF/;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

eval { require GD; };
plan(skip_all => 'GD not installed') if $@;

my $t = Test::Nginx->new()->has(qw/http image_filter ssi addition/)->plan(4)
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

        location /size {
            image_filter size;
            alias %%TESTDIR%%/;
        }

        location /ssi.html {
            ssi on;
        }

        location /before.html {
            add_before_body /size/png;
        }

        location /after.html {
            add_after_body /size/png;
        }
    }
}

EOF

my $im = new GD::Image(10, 12);
my $white = $im->colorAllocate(255, 255, 255);

$t->write_file('png', $im->png);
$t->write_file('ssi.html', 'X<!--#include virtual="/size/png" -->X');
$t->write_file('before.html', 'SEE-THIS');
$t->write_file('after.html', 'SEE-THIS');

$t->run();

###############################################################################

my $CRLF = CRLF;
my $json = '{ "img" : { "width": 10, "height": 12, "type": "png" } }' . CRLF;

like(http_get('/size/png'), qr/\Q$json\E$/, 'size');

TODO: {
local $TODO = 'not yet' unless $t->has_version('1.31.10');

like(http_get('/ssi.html'), qr/X\Q$json\EX$/, 'size in ssi include');
like(get('/before.html'), qr/\Q$json\E${CRLF}8${CRLF}SEE-THIS${CRLF}0$CRLF/,
	'size before body');
like(get('/after.html'), qr/SEE-THIS$CRLF\w+$CRLF\Q$json\E${CRLF}0$CRLF/,
	'size after body');

}

###############################################################################

sub get {
	my ($uri) = @_;
	return http(<<EOF);
GET $uri HTTP/1.1
Host: localhost
Connection: close

EOF
}

###############################################################################
