#!/usr/bin/perl

# (C) Nginx, Inc.

# Tests for PROXY protocol v2 with split TCP segments.
# Verifies that nginx correctly handles PPv2 headers that arrive
# in multiple TCP segments rather than a single read.

###############################################################################

use warnings;
use strict;

use Test::More;

use IO::Select;
use IO::Socket;
use Socket qw/ IPPROTO_TCP TCP_NODELAY $CRLF /;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;
use Test::Nginx::Stream qw/ stream /;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/stream stream_return/)->plan(9)
	->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

stream {
    %%TEST_GLOBALS_STREAM%%

    server {
        listen 127.0.0.1:8080 proxy_protocol;
        proxy_protocol_timeout 5s;
        return $proxy_protocol_addr;
    }
}

EOF

$t->run();

###############################################################################

# PPv2 header with IPv4 addresses (28 bytes total: 16 fixed + 12 addr)

my $p = pack("N3C", 0x0D0A0D0A, 0x000D0A51, 0x5549540A, 0x21);
my $tcp4 = $p . pack("CnN2n2", 0x11, 12, 0xc0000201, 0xc0000202, 123, 5678);

# PPv2 header with TLVs to make it larger

my $tlv = '';
$tlv .= pp2_create_tlv(0x01, "h2");
$tlv .= pp2_create_tlv(0x02, "example.com");
$tlv .= pp2_create_tlv(0x05, "unique-id-12345");
$tlv .= pp2_create_tlv(0x30, "my-network-namespace");
$tlv .= pp2_create_tlv(0xE0, "X" x 200);
my $tcp4_tlv = pp2_create($tlv);

# Test 1: complete PPv2 header sent at once (baseline)

is(pp_split_get(port(8080), $tcp4, undef), '192.0.2.1',
	'complete send - no split');

# Test 2: split after PPv2 signature (12 bytes)

is(pp_split_get(port(8080), $tcp4, 12), '192.0.2.1',
	'split after signature');

# Test 3: split after fixed header (16 bytes)

is(pp_split_get(port(8080), $tcp4, 16), '192.0.2.1',
	'split after fixed header');

# Test 4: split at 14 bytes (mid-length field)

is(pp_split_get(port(8080), $tcp4, 14), '192.0.2.1',
	'split mid-length field');

# Test 5: split at 1 byte

is(pp_split_get(port(8080), $tcp4, 1), '192.0.2.1',
	'split after 1 byte');

# Test 6: large PPv2 header with TLVs, split near end

my $total_len = length($tcp4_tlv);
is(pp_split_get(port(8080), $tcp4_tlv, $total_len - 10), '192.0.2.1',
	'large header split near end');

# Test 7: large PPv2 header, split after fixed header

is(pp_split_get(port(8080), $tcp4_tlv, 16), '192.0.2.1',
	'large header split after fixed header');

# Test 8: PROXY protocol v1 split

my $ppv1 = "PROXY TCP4 192.0.2.1 192.0.2.2 123 5678${CRLF}";
is(pp_split_get(port(8080), $ppv1, 20), '192.0.2.1',
	'v1 split mid-header');

# Test 9: three-segment send

is(pp_triple_get(port(8080), $tcp4_tlv, 16, 100), '192.0.2.1',
	'three-segment send');

###############################################################################

sub pp_split_get {
	my ($port, $proxy, $split_at) = @_;
	my $data = '';

	eval {
		local $SIG{ALRM} = sub { die "timeout\n" };
		local $SIG{PIPE} = 'IGNORE';
		alarm(3);

		my $s = IO::Socket::INET->new(
			Proto => 'tcp',
			PeerAddr => "127.0.0.1:$port",
		)
			or die "Can't connect: $!\n";

		$s->setsockopt(IPPROTO_TCP, TCP_NODELAY, 1);

		if (defined $split_at && $split_at > 0
			&& $split_at < length($proxy))
		{
			$s->syswrite(substr($proxy, 0, $split_at));
			select undef, undef, undef, 0.05;
			$s->syswrite(substr($proxy, $split_at));
		} else {
			$s->syswrite($proxy);
		}

		$s->syswrite("test");
		$s->shutdown(1);

		$s->blocking(0);
		while (IO::Select->new($s)->can_read(1)) {
			my $buf;
			my $n = $s->sysread($buf, 1024);
			last unless $n;
			$data .= $buf;
		}

		$s->close();
		alarm(0);
	};
	alarm(0);

	return $data;
}

sub pp_triple_get {
	my ($port, $proxy, $split1, $split2) = @_;
	my $data = '';

	eval {
		local $SIG{ALRM} = sub { die "timeout\n" };
		local $SIG{PIPE} = 'IGNORE';
		alarm(3);

		my $s = IO::Socket::INET->new(
			Proto => 'tcp',
			PeerAddr => "127.0.0.1:$port",
		)
			or die "Can't connect: $!\n";

		$s->setsockopt(IPPROTO_TCP, TCP_NODELAY, 1);

		$s->syswrite(substr($proxy, 0, $split1));
		select undef, undef, undef, 0.05;
		$s->syswrite(substr($proxy, $split1, $split2 - $split1));
		select undef, undef, undef, 0.05;
		$s->syswrite(substr($proxy, $split2));

		$s->syswrite("test");
		$s->shutdown(1);

		$s->blocking(0);
		while (IO::Select->new($s)->can_read(1)) {
			my $buf;
			my $n = $s->sysread($buf, 1024);
			last unless $n;
			$data .= $buf;
		}

		$s->close();
		alarm(0);
	};
	alarm(0);

	return $data;
}

sub pp2_create {
	my ($tlv) = @_;

	my $pp2_sig = pack("N3", 0x0D0A0D0A, 0x000D0A51, 0x5549540A);
	my $ver_cmd = pack('C', 0x21);
	my $family = pack('C', 0x11);
	my $packet = $pp2_sig . $ver_cmd . $family;

	my $ip1 = pack('N', 0xc0000201); # 192.0.2.1
	my $ip2 = pack('N', 0xc0000202); # 192.0.2.2
	my $port1 = pack('n', 123);
	my $port2 = pack('n', 5678);
	my $addrs = $ip1 . $ip2 . $port1 . $port2;

	my $len = length($addrs) + length($tlv);

	$packet .= pack('n', $len) . $addrs . $tlv;

	return $packet;
}

sub pp2_create_tlv {
	my ($type, $content) = @_;

	my $len = length($content);

	return pack("CnA*", $type, $len, $content);
}

###############################################################################
