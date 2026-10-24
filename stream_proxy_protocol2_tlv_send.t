#!/usr/bin/perl

# (C) Nginx, Inc.

# Tests for stream proxy module, sending PROXY protocol v2 TLVs.

###############################################################################

use warnings;
use strict;

use Test::More;

use File::Spec;
use IO::Socket::INET;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;
use Test::Nginx::Stream qw/ stream /;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

local $SIG{PIPE} = 'IGNORE';

my $t = Test::Nginx->new()->has(qw/stream/)->plan(14)
	->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

stream {
    %%TEST_GLOBALS_STREAM%%

    proxy_protocol         v2;
    proxy_protocol_v2_tlv  0xe5  inherited;

    server {
        listen      127.0.0.1:8080;
        proxy_pass  127.0.0.1:8081;

        proxy_protocol_v2_tlv  0xE0  literal;
        proxy_protocol_v2_tlv  0xf7  "with space";
        proxy_protocol_v2_tlv  0xff  "";
    }

    server {
        listen      127.0.0.1:8082;
        proxy_pass  127.0.0.1:8081;

        proxy_protocol_v2_tlv  0xe1  "port:$server_port";
    }

    server {
        listen      127.0.0.1:8083;
        proxy_pass  127.0.0.1:8081;
    }

    server {
        listen      127.0.0.1:8084;
        proxy_pass  127.0.0.1:8081;

        proxy_protocol  on;

        proxy_protocol_v2_tlv  0xe0  ignored;
    }
}

EOF

$t->run_daemon(\&pp2_daemon);
$t->run();

$t->waitforsocket('127.0.0.1:' . port(8081));

###############################################################################

my $r = stream(PeerPort => port(8080))->read();

like($r, qr/0xe0=\[literal\]/, 'literal value, uppercase type');
like($r, qr/0xf7=\[with space\]/, 'experimental type, value with space');
like($r, qr/0xff=\[\]/, 'empty value is sent as a zero-length TLV');
like($r, qr/^types:(?:\w\w,)*03 /, 'CRC32c is written last');
like($r, qr/0xe0=\[literal\] 0xf7=\[with space\] 0xff=\[\]/,
	'TLVs are written in the configured order');

$r = stream(PeerPort => port(8082))->read();

like($r, qr/0xe1=\[port:${\ port(8082)}\]/, 'value with a variable');
unlike($r, qr/0xe5=/, 'server level replaces the inherited set');

$r = stream(PeerPort => port(8083))->read();

like($r, qr/0xe5=\[inherited\]/, 'inherited from the stream level');

$r = stream(PeerPort => port(8084))->read();

is($r, '', 'no TLVs with version 1');

# the type must be a lowercase "0x" prefix plus exactly two hex digits,
# and each type may appear only once

my $d = $t->testdir();

ok(tlv_test($d, 'proxy_protocol_v2_tlv  0xe0  a;'),
	'lowercase two-digit type');
ok(tlv_test($d, 'proxy_protocol_v2_tlv  0xE0  a;'),
	'uppercase hex digits');
ok(!tlv_test($d, 'proxy_protocol_v2_tlv  0XE0  a;'),
	'uppercase "0X" prefix is rejected');
ok(!tlv_test($d, 'proxy_protocol_v2_tlv  0x0e0  a;'),
	'zero-padded type is rejected');
ok(!tlv_test($d, "proxy_protocol_v2_tlv  0xe0  a;\n"
	. "        proxy_protocol_v2_tlv  0xE0  b;"),
	'duplicate type is rejected');

###############################################################################

# runs "nginx -t" over a config with the given proxy_protocol_v2_tlv lines

sub tlv_test {
	my ($dir, $tlvs) = @_;
	my $rc;

	open my $fh, '>', "$dir/test.conf" or die "Can't write config: $!";

	print $fh <<"EOF";
daemon off;
pid $dir/test.pid;
error_log $dir/test_error.log;

events {
}

stream {
    server {
        listen      127.0.0.1:@{[port(8085)]};
        proxy_pass  127.0.0.1:@{[port(8081)]};

        proxy_protocol  v2;
        $tlvs
    }
}
EOF

	close $fh;

	open my $olderr, '>&', \*STDERR;
	open STDERR, '>', File::Spec->devnull();

	$rc = system($Test::Nginx::NGINX, '-t',
		'-p', $dir . '/', '-c', 'test.conf');

	open STDERR, '>&', $olderr;

	return $rc == 0;
}


sub pp2_daemon {
	my $server = IO::Socket::INET->new(
		Proto => 'tcp',
		LocalAddr => '127.0.0.1:' . port(8081),
		Listen => 5,
		Reuse => 1
	)
		or die "Can't create listening socket: $!\n";

	local $SIG{PIPE} = 'IGNORE';

	while (my $client = $server->accept()) {
		$client->autoflush(1);

		my $hdr = pp2_read($client, 16);

		# version 1 sends a text header, which has no TLVs

		unless (defined $hdr
			&& $hdr =~ /^\x0d\x0a\x0d\x0a\x00\x0d\x0aQUIT\x0a/)
		{
			close $client;
			next;
		}

		my $family = unpack('C', substr($hdr, 13, 1));
		my $body = pp2_read($client, unpack('n', substr($hdr, 14, 2)));

		# skip the address block

		my $tlvs = substr($body, ($family >> 4) == 2 ? 36 : 12);

		my (@types, @out);

		while (length($tlvs) >= 3) {
			my ($type, $len) = unpack('Cn', $tlvs);
			my $value = substr($tlvs, 3, $len);

			$tlvs = substr($tlvs, 3 + $len);

			push @types, sprintf('%02x', $type);

			next if $type < 0xe0;

			push @out, sprintf('0x%02x=[%s]', $type, $value);
		}

		print $client 'types:' . join(',', @types) . ' '
			. join(' ', @out) . "\n";

		close $client;
	}
}

sub pp2_read {
	my ($client, $len) = @_;
	my $buf = '';

	while (length($buf) < $len) {
		my $n = $client->sysread(my $chunk, $len - length($buf));
		return undef unless $n;
		$buf .= $chunk;
	}

	return $buf;
}

###############################################################################
