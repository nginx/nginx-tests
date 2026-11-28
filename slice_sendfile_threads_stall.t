#!/usr/bin/perl

# (C) Gcore

# Test for a stalled response with slice, sendfile and aio threads.
#
# A slice subrequest is finalized while its sendfile() thread task is still
# running.  A write event that arrives before the task completion is then
# handled by the main request, which calls ngx_linux_sendfile_thread() again
# and clears wev->complete.  If the task returned EAGAIN, the write event is
# marked not ready although the socket is writable, and the response waits
# for send_timeout.
#
# A small send buffer on the listening socket and small client receive
# buffers make sendfile() return EAGAIN often.

###############################################################################

use warnings;
use strict;

use Test::More;

use IO::Select;
use IO::Socket::INET;
use Socket qw/ SOL_SOCKET SO_RCVBUF pack_sockaddr_in inet_aton /;
use Time::HiRes qw/ time /;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/http proxy cache slice threads/)->plan(2);

$t->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
    worker_connections  1024;
}

http {
    %%TEST_GLOBALS_HTTP%%

    proxy_cache_path   %%TESTDIR%%/cache  keys_zone=NAME:1m;
    proxy_cache_key    $uri$slice_range;

    server {
        listen       127.0.0.1:8080 sndbuf=8k;
        server_name  localhost;

        sendfile      on;
        aio           threads;
        send_timeout  60s;

        location / {
            slice 64k;

            proxy_pass    http://127.0.0.1:8081;

            proxy_cache   NAME;

            proxy_set_header   Range  $slice_range;

            proxy_cache_valid   200 206  1h;
        }
    }

    server {
        listen       127.0.0.1:8081;
        server_name  localhost;

        location / { }
    }
}

EOF

my $size = 1024 * 1024;
my $clients = 16;
my $requests = 1500;
my $idle = 3;

# debug logging slows the event loop enough to hide the race

my $conf = $t->read_file('nginx.conf');
$conf =~ s/(error_log \S+) debug;/$1 info;/;
$t->write_file('nginx.conf', $conf);

$t->write_file('object', 'x' x $size);
$t->run();

###############################################################################

like(http_get('/object'), qr/^HTTP\/1.1 200 /, 'cache filled');

TODO: {
local $TODO = 'not yet' unless $t->has_version('1.31.11');

is(stress(), "stalled 0, complete $requests", 'no stalled responses');
}

###############################################################################

sub stress {
	my ($started, $stalled, $complete) = (0, 0, 0);
	my $select = IO::Select->new();
	my %state;

	while ($started < $requests || $select->count()) {

		while ($started < $requests && $select->count() < $clients) {
			my $s = IO::Socket::INET->new(Proto => 'tcp');
			$s->setsockopt(SOL_SOCKET, SO_RCVBUF, 4096);
			$s->connect(pack_sockaddr_in(port(8080), inet_aton('127.0.0.1')))
				or die "connect: $!\n";
			$s->syswrite("GET /object HTTP/1.0\r\nHost: localhost\r\n\r\n");
			$select->add($s);
			$state{$s} = { bytes => 0, last => time() };
			$started++;
		}

		for my $s ($select->can_read(0.5)) {
			my $n = $s->sysread(my $buf, 1024);

			if ($n) {
				$state{$s}{bytes} += $n;
				$state{$s}{last} = time();
				next;
			}

			$complete++ if $state{$s}{bytes} > $size;
			delete $state{$s};
			$select->remove($s);
			$s->close();
		}

		my $now = time();

		for my $s ($select->handles()) {
			next if $now - $state{$s}{last} < $idle;

			$stalled++;
			delete $state{$s};
			$select->remove($s);
			$s->close();
		}
	}

	return "stalled $stalled, complete $complete";
}

###############################################################################
