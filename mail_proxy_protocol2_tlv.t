#!/usr/bin/perl

# (C) Nginx, Inc.

# Tests for mail proxy module, sending PROXY protocol v2 TLVs.

###############################################################################

use warnings;
use strict;

use Test::More;

use MIME::Base64;
use File::Spec;
use IO::Socket::INET;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;
use Test::Nginx::SMTP;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

local $SIG{PIPE} = 'IGNORE';

use constant CRLF => "\x0D\x0A";

my $t = Test::Nginx->new()->has(qw/mail smtp http rewrite/)
	->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

mail {
    proxy_pass_error_message  on;
    proxy_timeout             15s;
    proxy_smtp_auth           on;
    proxy_protocol            v2;
    proxy_protocol_v2_tlv     0xe5  inherited;

    auth_http  http://127.0.0.1:8080/mail/auth;
    smtp_auth  login plain;

    server {
        listen    127.0.0.1:8025;
        protocol  smtp;

        proxy_protocol_v2_tlv  0xE0  literal;
        proxy_protocol_v2_tlv  0xf7  "with space";
        proxy_protocol_v2_tlv  0xff  "";
    }

    server {
        listen    127.0.0.1:8027;
        protocol  smtp;
    }

    server {
        listen    127.0.0.1:8028;
        protocol  smtp;

        proxy_protocol  on;

        proxy_protocol_v2_tlv  0xe0  ignored;
    }
}

http {
    %%TEST_GLOBALS_HTTP%%

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        location = /mail/auth {
            add_header Auth-Status OK;
            add_header Auth-Server 127.0.0.1;
            add_header Auth-Port %%PORT_8026%%;
            add_header Auth-Wait 1;
            return 204;
        }
    }
}

EOF

$t->run_daemon(\&pp2_smtp_daemon);
$t->run()->plan(15);

$t->waitforsocket('127.0.0.1:' . port(8026));

###############################################################################

# TLVs configured on the server level

my $s = Test::Nginx::SMTP->new(PeerAddr => '127.0.0.1:' . port(8025));
$s->check(qr/^220 /, 'greeting');

$s->send('EHLO example.com');
$s->check(qr/^250 /, 'ehlo');

$s->send('AUTH PLAIN ' . encode_base64("\0test\@example.com\0secret", ''));
$s->authok('auth');

$s->send('XPROXY');
my $r = $s->read();

like($r, qr/0xe0=\[literal\]/, 'literal value, uppercase type');
like($r, qr/0xf7=\[with space\]/, 'experimental type, value with space');
like($r, qr/0xff=\[\]/, 'empty value is sent as a zero-length TLV');
like($r, qr/0xe0=\[literal\] 0xf7=\[with space\] 0xff=\[\]/,
	'TLVs are written in the configured order');
unlike($r, qr/0xe5=/, 'server level replaces the inherited set');

# TLVs inherited from the mail level

$s = Test::Nginx::SMTP->new(PeerAddr => '127.0.0.1:' . port(8027));
$s->read();

$s->send('EHLO example.com');
$s->read();

$s->send('AUTH PLAIN ' . encode_base64("\0test\@example.com\0secret", ''));
$s->read();

$s->send('XPROXY');

like($s->read(), qr/0xe5=\[inherited\]/, 'inherited from the mail level');

# version 1 ignores the configured TLVs

$s = Test::Nginx::SMTP->new(PeerAddr => '127.0.0.1:' . port(8028));
$s->read();

$s->send('EHLO example.com');
$s->read();

$s->send('AUTH PLAIN ' . encode_base64("\0test\@example.com\0secret", ''));
$s->read();

$s->send('XPROXY');

like($s->read(), qr/^211 v1\x0d?$/, 'no TLVs with version 1');

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

mail {
    auth_http  http://127.0.0.1:@{[port(8080)]}/mail/auth;

    server {
        listen    127.0.0.1:@{[port(8029)]};
        protocol  smtp;

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


sub pp2_smtp_daemon {
	my $server = IO::Socket::INET->new(
		Proto => 'tcp',
		LocalAddr => '127.0.0.1:' . port(8026),
		Listen => 5,
		Reuse => 1
	)
		or die "Can't create listening socket: $!\n";

	local $SIG{PIPE} = 'IGNORE';

	while (my $client = $server->accept()) {
		$client->autoflush(1);

		my $tlvs = pp2_tlvs($client);

		print $client '220 fake esmtp server ready' . CRLF;

		while (<$client>) {
			Test::Nginx::log_core('||', $_);

			if (/^quit/i) {
				print $client '221 quit ok' . CRLF;
			} elsif (/^(ehlo|helo)/i) {
				print $client '250 hello ok' . CRLF;
			} elsif (/^auth plain/i) {
				print $client '235 auth ok' . CRLF;
			} elsif (/^xclient/i) {
				print $client '220 xclient ok' . CRLF;
			} elsif (/^mail from:/i) {
				print $client '250 mail from ok' . CRLF;
			} elsif (/^rcpt to:/i) {
				print $client '250 rcpt to ok' . CRLF;
			} elsif (/^xproxy/i) {
				print $client '211 ' . $tlvs . CRLF;
			} else {
				print $client '500 unknown command' . CRLF;
			}
		}

		close $client;
	}
}

# reads the PROXY protocol header and returns a summary of its TLVs

sub pp2_tlvs {
	my ($client) = @_;

	my $hdr = pp2_read($client, 16);

	return 'closed' unless defined $hdr;

	# version 1 sends a text header, which has no TLVs

	unless ($hdr =~ /^\x0d\x0a\x0d\x0a\x00\x0d\x0aQUIT\x0a/) {

		# consume the rest of the text header

		$client->sysread(my $rest, 1024) unless $hdr =~ /\x0a$/;

		return 'v1';
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

	return 'types:' . join(',', @types) . ' ' . join(' ', @out);
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
