#!/usr/bin/perl

# Tests for variable stream proxy_protocol configuration.

###############################################################################

use warnings;
use strict;

use Test::More;
use Socket qw/ CRLF inet_aton /;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;
use Test::Nginx::Stream qw/ stream /;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/stream stream_map/)->plan(31);

my $config = <<'EOF';
%%TEST_GLOBALS%%

daemon off;

events {
}

stream {
    %%TEST_GLOBALS_STREAM%%

    map $proxy_protocol_server_port $pp_version {
        1       on;
        2       off;
        3       v2;
        4       ON;
        5       OFF;
        6       V2;
        7       invalid;
        8       "";
        default on;
    }

    map $remote_addr $version {
        default 2;
    }

    PARENT

    server {
        listen 127.0.0.1:8080 proxy_protocol;
        proxy_pass 127.0.0.1:8081;
    }

    server {
        listen 127.0.0.1:8082 proxy_protocol;
        proxy_pass 127.0.0.1:8081;
        proxy_protocol off;
    }

    server {
        listen 127.0.0.1:8083 proxy_protocol;
        proxy_pass 127.0.0.1:8081;
        proxy_protocol on;
    }

    server {
        listen 127.0.0.1:8084 proxy_protocol;
        proxy_pass 127.0.0.1:8081;
        proxy_protocol v2;
    }

    server {
        listen 127.0.0.1:8085 proxy_protocol;
        proxy_pass 127.0.0.1:8081;
        proxy_protocol $pp_version;
    }

    server {
        listen 127.0.0.1:8086 proxy_protocol;
        proxy_pass 127.0.0.1:8081;
        proxy_protocol v${version};
    }
}
EOF

configure('proxy_protocol $pp_version;');
$t->run_daemon(\&echo_daemon);
$t->waitforsocket('127.0.0.1:' . port(8081));
$t->run();

###############################################################################

for my $case ([1, 1], [2, 0], [3, 2], [4, 1], [5, 0], [6, 2]) {
	check(8080, @$case, "inherited variable $case->[0]");
}

check(8080, 1, 1, 'variable reevaluated for next session');
check(8082, 1, 0, 'static off overrides variable');
check(8083, 2, 1, 'static on overrides variable');
check(8084, 2, 2, 'static v2 overrides variable');
check(8086, 2, 2, 'complex value with literal prefix');
check(8080, 7, -1, 'invalid variable rejects session');
check(8080, 8, -1, 'empty variable rejects session');

$t->stop();

like($t->read_file('error.log'),
	qr/invalid proxy_protocol value "invalid"/, 'invalid value logged');
like($t->read_file('error.log'),
	qr/invalid proxy_protocol value ""/, 'empty value logged');

configure('proxy_protocol on;');
$t->run();

check(8080, 2, 1, 'inherited static on');
check(8085, 2, 0, 'variable off overrides static on');
check(8085, 3, 2, 'variable v2 overrides static on');

$t->stop();

configure('');
$t->run();

check(8080, 1, 0, 'default off');
check(8085, 1, 1, 'variable on without parent setting');

$t->stop();

for my $value ('ON', 'OFF', 'V2') {
	configure("proxy_protocol $value;");
	like($t->dump_config(), qr/test is successful/, "static $value accepted");
}

for my $value ('invalid', '""') {
	configure("proxy_protocol $value;");
	like($t->dump_config(), qr/invalid value/, "static $value rejected");
}

for my $directives ('on; proxy_protocol off',
	'on; proxy_protocol $pp_version', '$pp_version; proxy_protocol on',
	'$pp_version; proxy_protocol $pp_version')
{
	configure("proxy_protocol $directives;");
	like($t->dump_config(), qr/is duplicate/, 'duplicate directive rejected');
}

configure('proxy_protocol $unknown_protocol;');
like($t->dump_config(), qr/unknown "unknown_protocol" variable/,
	'unknown variable rejected');

configure('proxy_protocol ${pp_version;');
like($t->dump_config(), qr/the closing bracket/, 'malformed variable rejected');

undef $t;

###############################################################################

sub configure {
	my ($parent) = @_;
	my $conf = $config;
	$conf =~ s/PARENT/$parent/;
	$t->write_file_expand('nginx.conf', $conf);
}

sub check {
	my ($listen, $selector, $version, $name) = @_;
	my $dp = port($listen);
	my $s = stream('127.0.0.1:' . $dp);
	my $sp = $s->sockport();
	my $expected = 'close';

	if ($version == 1) {
		$expected = "PROXY TCP4 127.0.0.1 127.0.0.1 $sp $dp" . CRLF
			. $expected;

	} elsif ($version == 2) {
		my $header = "\r\n\r\n\0\r\nQUIT\n" . pack('CCn', 0x21, 0x11, 19)
			. inet_aton('127.0.0.1') x 2 . pack('nn', $sp, $dp)
			. pack('CnN', 3, 4, 0);
		substr($header, -4) = pack('N', crc32c($header));
		$expected = $header . $expected;

	} elsif ($version == -1) {
		$expected = '';
	}

	is($s->io("PROXY TCP4 192.0.2.1 192.0.2.2 12345 $selector" . CRLF
		. 'close'), $expected, $name);
}

sub crc32c {
	my ($data) = @_;
	my $crc = 0xffffffff;

	for my $byte (unpack('C*', $data)) {
		$crc ^= $byte;
		for (1 .. 8) {
			$crc = ($crc >> 1) ^ (($crc & 1) ? 0x82f63b78 : 0);
		}
	}

	return $crc ^ 0xffffffff;
}

sub echo_daemon {
	my $server = IO::Socket::INET->new(
		Proto => 'tcp',
		LocalAddr => '127.0.0.1:' . port(8081),
		Listen => 5,
		Reuse => 1
	) or die "Can't create listening socket: $!\n";

	local $SIG{PIPE} = 'IGNORE';

	while (my $client = $server->accept()) {
		my $data = '';
		while ($client->sysread(my $buffer, 65536)) {
			$data .= $buffer;
			last if $data =~ /close\z/;
		}
		while (length $data) {
			my $n = $client->syswrite($data);
			last unless $n;
			substr($data, 0, $n, '');
		}
		close $client;
	}
}

###############################################################################
