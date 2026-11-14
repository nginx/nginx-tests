#!/usr/bin/perl

# (c) Eugene Grebenschikov

# Tests for stream proxy error reporting when an upstream connection fails.

###############################################################################

use warnings;
use strict;

use Test::More;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;
use Test::Nginx::Stream qw/ stream /;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/stream/)
	->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

stream {
    %%TEST_GLOBALS_STREAM%%

    log_format test "$status:$upstream_addr";

    upstream refused {
        server 127.0.0.1:8083;
    }

    upstream failover {
        server 127.0.0.1:8083;
        server 127.0.0.1:8084 backup;
    }

    upstream finwait {
        server 127.0.0.1:8085 max_fails=0;
        server 127.0.0.1:8084 backup;
    }

    server {
        listen      127.0.0.1:8080;
        proxy_pass  refused;
    }

    server {
        listen      127.0.0.1:8081;
        proxy_pass  failover;
        access_log  %%TESTDIR%%/failover.log test;
    }

    server {
        listen      127.0.0.1:8082;
        proxy_pass  finwait;
    }
}

EOF

$t->run_daemon(\&stream_daemon, port(8084));
$t->run_daemon(\&fin_daemon, port(8085));
$t->run()->plan(5);

$t->waitforsocket('127.0.0.1:' . port(8084))
	or die "cannot start stream daemon";
$t->waitforsocket('127.0.0.1:' . port(8085))
	or die "cannot start fin daemon";

###############################################################################

is(stream('127.0.0.1:' . port(8080))->io('test'), '', 'connection refused');
is(stream('127.0.0.1:' . port(8081))->io('test'), 'test', 'next upstream');

my $p2 = port(8082);

my $fin = burst($p2, 100);

$t->stop();

my $log = $t->read_file('error.log');

like($log, qr/connect\(\) .*failed .*while connecting to upstream/,
	'connect() failed reported');

like($t->read_file('failover.log'), qr/127\.0\.0\.1:\d+, 127\.0\.0\.1:\d+/,
	'both upstreams tried');

SKIP: {
skip "need kqueue", 1 unless $log =~ qr/using the "kqueue" event method/;
skip "no pending_eof reported", 1 unless grep {
	/kevent\(\) reported that connect\(\) failed/
	&& /server: 127\.0\.0\.1:$p2,/
	} split /\n/, $log;

is($fin, 'test', 'fin wait - next upstream');

}

###############################################################################

sub stream_daemon {
	my ($port) = @_;

	my $server = IO::Socket::INET->new(
		Proto => 'tcp',
		LocalHost => '127.0.0.1',
		LocalPort => $port,
		Listen => 512,
		Reuse => 1
	)
		or die "Can't create listening socket: $!\n";

	local $SIG{PIPE} = 'IGNORE';

	while (my $client = $server->accept()) {
		$client->autoflush(1);

		$client->sysread(my $buffer, 65536) or next;

		log2i("$client $buffer");
		log2o("$client $buffer");

		$client->syswrite($buffer);

		close $client;
	}
}

sub burst {
	my ($port, $n) = @_;

	my (@socks, $ret);

	for (1 .. $n) {
		my $s = IO::Socket::INET->new(
			Proto => 'tcp',
			PeerAddr => '127.0.0.1',
			PeerPort => $port
		) or next;

		push @socks, $s;
	}

	$_->syswrite('test') for @socks;

	for my $s (@socks) {
		eval {
			local $SIG{ALRM} = sub { die "timeout\n" };
			alarm 5;
			$s->sysread(my $buf, 1024);
			$ret ||= $buf;
			alarm 0;
		};

		close $s;
	}

	return $ret;
}

sub fin_daemon {
	my ($port) = @_;

	my $server = IO::Socket::INET->new(
		Proto => 'tcp',
		LocalHost => '127.0.0.1',
		LocalPort => $port,
		Listen => 512,
		Reuse => 1
	)
		or die "Can't create listening socket: $!\n";

	local $SIG{PIPE} = 'IGNORE';

	while (my $client = $server->accept()) {
		close $client;
	}
}

sub log2i { Test::Nginx::log_core('|| <<', @_); }
sub log2o { Test::Nginx::log_core('|| >>', @_); }
sub log2c { Test::Nginx::log_core('||', @_); }

###############################################################################
