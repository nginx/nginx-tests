#!/usr/bin/perl

# (C) Gabriel Clima
# (C) Gcore

# Tests for slice filter with a large cached response: a request on
# another connection must be handled while the cached slices are sent.
# The upstream module finalizes each slice subrequest after sending its
# cached body and the slice filter creates the next one, so the whole
# response is sent from one call of ngx_http_run_posted_requests()
# unless a write returns EAGAIN, which a fast enough client never causes.

###############################################################################

use warnings;
use strict;

use Test::More;

use IO::Select;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx qw/ :DEFAULT http_end /;

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

$t->write_file('big.bin', 'x' x (500 * 131072));
$t->write_file('small.txt', 'SEE-THIS');
$t->run();

###############################################################################

like(http_get('/big.bin'), qr/X-Cache-Status: MISS/, 'cache populated');

# a child reads the cached response as fast as it arrives; it signals
# the first bytes and the end of the response over a pipe

pipe(my $rd, my $wr) or die "pipe failed: $!";

my $pid = fork();
die "fork failed: $!" unless defined $pid;

if ($pid == 0) {
	close $rd;

	my $s = http_get('/big.bin', start => 1);
	my $buf;

	$s->sysread($buf, 1048576);
	syswrite($wr, 'first');

	1 while $s->sysread($buf, 1048576);
	syswrite($wr, 'done');

	exit 0;
}

close $wr;
sysread($rd, my $first, 5);

# the request on another connection is sent while the cached response
# is still being sent

my $s = http_get('/small.txt', start => 1);

ok(!IO::Select->new($rd)->can_read(0), 'large response in flight');

like(http_end($s), qr/SEE-THIS/, 'other connection');

waitpid($pid, 0);

TODO: {
local $TODO = 'not yet';

is($t->read_file('test.log'), "/big.bin\n/small.txt\n/big.bin\n",
	'other connection handled first');

}

###############################################################################
