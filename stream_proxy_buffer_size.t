#!/usr/bin/perl

# (C) Feng Wu

# Tests for stream proxy module, proxy_buffer_size directive.

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

my $t = Test::Nginx->new()->has(qw/stream/)->plan(2)
	->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

stream {
    %%TEST_GLOBALS_STREAM%%

    server {
        listen      127.0.0.1:8080;
        proxy_pass  127.0.0.1:8081;
        proxy_buffer_size 0;
    }
}

EOF

my $testdir = $t->testdir();
my $cmd = "$Test::Nginx::NGINX -t -p $testdir/ -c nginx.conf "
	. "-e error.log 2>&1";

`$cmd`;

isnt($?, 0, 'proxy_buffer_size zero rejected');
like($t->read_file('error.log'), qr/"proxy_buffer_size" must be greater/,
	'proxy_buffer_size zero');

###############################################################################
