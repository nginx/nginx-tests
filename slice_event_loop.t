#!/usr/bin/perl

# (C) Gabriel Clima
# (C) Gcore

# Tests for slice filter with a large cached response and another connection.

###############################################################################

use warnings;
use strict;

use Test::More;

use IO::Select;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/http proxy cache slice/)->plan(4)
	->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    log_format test $uri;

    proxy_cache_path   %%TESTDIR%%/cache  keys_zone=NAME:10m;
    proxy_cache_key    $uri$slice_range;

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        access_log %%TESTDIR%%/test.log test;

        location / {
            slice 128k;

            proxy_pass    http://127.0.0.1:8081/;
            proxy_cache   NAME;

            proxy_set_header   Range  $slice_range;
            proxy_cache_valid  200 206  1h;

            add_header X-Cache-Status $upstream_cache_status;
        }
    }

    server {
        listen       127.0.0.1:8081;
        server_name  localhost;

        root %%TESTDIR%%;
    }
}

EOF

$t->write_file('big.bin', 'x' x (64 * 131072));
$t->write_file('small.txt', 'SEE-THIS');
$t->run();

###############################################################################

like(http_get('/big.bin'), qr/X-Cache-Status: MISS/, 'cache populated');

my $s = http_get('/big.bin', start => 1);
my $sel = IO::Select->new($s);
my $first = '';

$s->sysread($first, 65536) if $sel->can_read(5);

like($first, qr/X-Cache-Status: HIT/, 'cached');

# another connection is handled while the cached slices are sent

my $s2 = http_get('/small.txt', start => 1);
$sel->add($s2);

my $small = '';

while ($sel->count) {
	my @ready = $sel->can_read(10) or last;

	for my $fh (@ready) {
		my $n = $fh->sysread(my $buf, 65536);
		$small .= $buf if $n && $fh == $s2;
		$sel->remove($fh) unless $n;
	}
}

like($small, qr/SEE-THIS/, 'other connection');

TODO: {
local $TODO = 'not yet';

is($t->read_file('test.log'), "/big.bin\n/small.txt\n/big.bin\n",
	'other connection handled first');

}

###############################################################################
