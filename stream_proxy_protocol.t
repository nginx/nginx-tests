#!/usr/bin/perl

# (C) Andrey Zelenkov
# (C) Nginx, Inc.

# Tests for stream proxy module with haproxy protocol.

###############################################################################

use warnings;
use strict;

use Test::More;

use IO::Select;
use Socket qw/ $CRLF /;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;
use Test::Nginx::Stream qw/ stream /;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/stream stream_realip/)
	->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

stream {
    %%TEST_GLOBALS_STREAM%%

    proxy_protocol on;

    server {
        listen          127.0.0.1:8080;
        proxy_pass      127.0.0.1:8081;
    }

    server {
        listen          127.0.0.1:8082;
        proxy_pass      127.0.0.1:8081;
        proxy_protocol  off;
    }

    server {
        listen          127.0.0.1:8083 proxy_protocol;
        set_real_ip_from 127.0.0.1;
        proxy_pass      127.0.0.1:8081;
    }

    server {
        listen          127.0.0.1:8086 proxy_protocol;
        proxy_pass      127.0.0.1:8081;
    }

    server {
        listen          127.0.0.1:8084;
        proxy_pass      [::1]:%%PORT_8085%%;
    }

    server {
        listen          [::1]:%%PORT_8085%% proxy_protocol;
        set_real_ip_from ::1;
        proxy_pass      127.0.0.1:8081;
    }
}

EOF

$t->run_daemon(\&stream_daemon);
$t->try_run('no inet6 support')->plan(5);
$t->waitforsocket('127.0.0.1:' . port(8081));

###############################################################################

my $dp = port(8080);
my $s = stream('127.0.0.1:' . $dp);
my $data = $s->io('close');
my $sp = $s->sockport();
is($data, "PROXY TCP4 127.0.0.1 127.0.0.1 $sp $dp${CRLF}close", 'protocol on');

is(stream('127.0.0.1:' . port(8082))->io('close'), 'close', 'protocol off');

is(stream('127.0.0.1:' . port(8083))->io(
	"PROXY TCP6 2001:db8::1 2001:db8::2 1234 5678${CRLF}close"),
	"PROXY TCP6 2001:db8::1 2001:db8::2 1234 5678${CRLF}close",
	'protocol incoming tuple');

my $p = pack("N3C", 0x0D0A0D0A, 0x000D0A51, 0x5549540A, 0x21);
my $tcp4 = $p . pack("CnN2n2", 0x11, 12, 0xc0000201, 0xc0000202,
	1234, 5678);

is(stream('127.0.0.1:' . port(8086))->io($tcp4 . 'close'),
	"PROXY TCP4 192.0.2.1 192.0.2.2 1234 5678${CRLF}close",
	'protocol v2 incoming tuple');

my $dp4 = port(8084);
my $s4 = stream('127.0.0.1:' . $dp4);
my $data4 = $s4->io('close');
my $sp4 = $s4->sockport();
is($data4, "PROXY TCP4 127.0.0.1 127.0.0.1 $sp4 $dp4${CRLF}close",
	'protocol incoming tuple through ipv6 hop');

###############################################################################

sub stream_daemon {
	my $server = IO::Socket::INET->new(
		Proto => 'tcp',
		LocalAddr => '127.0.0.1:' . port(8081),
		Listen => 5,
		Reuse => 1
	)
		or die "Can't create listening socket: $!\n";

	my $sel = IO::Select->new($server);

	local $SIG{PIPE} = 'IGNORE';

	while (my @ready = $sel->can_read) {
		foreach my $fh (@ready) {
			if ($server == $fh) {
				my $new = $fh->accept;
				$new->autoflush(1);
				$sel->add($new);

			} elsif (stream_handle_client($fh)) {
				$sel->remove($fh);
				$fh->close;
			}
		}
	}
}

sub stream_handle_client {
	my ($client) = @_;

	log2c("(new connection $client)");

	$client->sysread(my $buffer, 65536) or return 1;

	log2i("$client $buffer");

	log2o("$client $buffer");

	$client->syswrite($buffer);

	return $buffer =~ /close/;
}

sub log2i { Test::Nginx::log_core('|| <<', @_); }
sub log2o { Test::Nginx::log_core('|| >>', @_); }
sub log2c { Test::Nginx::log_core('||', @_); }

###############################################################################
