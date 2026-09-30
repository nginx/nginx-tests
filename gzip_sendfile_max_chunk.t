#!/usr/bin/perl

# (C) Nginx, Inc.

# Tests for sendfile_max_chunk with the gzip filter module.

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

my $t = Test::Nginx->new()->has(qw/http gzip/)->plan(2)
	->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    log_format test $uri;

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        root %%TESTDIR%%;

        access_log %%TESTDIR%%/test.log test;

        gzip on;
        gzip_types text/plain;

        sendfile_max_chunk 64k;
    }
}

EOF

$t->write_file('big.txt', join '', map { "line $_\n" } (1 .. 3000000));
$t->write_file('small.txt', 'SEE-THIS');
$t->run();

###############################################################################

my $s = http(<<EOF, start => 1);
GET /big.txt HTTP/1.1
Host: localhost
Accept-Encoding: gzip
Connection: close

EOF

my $sel = IO::Select->new($s);
my $first = '';

$s->sysread($first, 65536) if $sel->can_read(5);

like($first, qr/Content-Encoding: gzip/, 'gzip');

# another connection is handled while the response is compressed

my $s2 = http_get('/small.txt', start => 1);
$sel->add($s2);

while ($sel->count) {
	my @ready = $sel->can_read(10) or last;

	for my $fh (@ready) {
		$sel->remove($fh) unless $fh->sysread(my $buf, 65536);
	}
}

TODO: {
local $TODO = 'not yet';

is($t->read_file('test.log'), "/small.txt\n/big.txt\n", 'other connection');

}

###############################################################################
