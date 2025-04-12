#!/usr/bin/perl

# (C) Maxim Dounin

# Tests for nginx ssi module, waited subrequests.

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

my $t = Test::Nginx->new()->has(qw/http ssi/)->plan(2);

$t->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;
        location / {
            ssi on;
        }
    }
}

EOF

$t->write_file('test-stub.html', '<!--# block name="stub" -->STUB<!--# endblock -->' .
	'x<!--#include virtual="/empty.html" stub="stub" -->x');

$t->write_file('test-concurrent.html', 'x<!--#include virtual="/first.html" -->' .
  '<!--# block name="stub" -->STUB<!--# endblock -->' .
	'x<!--#include virtual="/empty.html" stub="stub" -->x');
$t->write_file('first.html', 'FIRST');
$t->write_file('empty.html', '');

$t->run();

###############################################################################

like(http_get('/test-stub.html'), qr/^xSTUBx$/m, 'stub');
like(http_get('/test-concurrent.html'), qr/^xFIRSTxSTUBx$/m, 'concurrent');

###############################################################################
