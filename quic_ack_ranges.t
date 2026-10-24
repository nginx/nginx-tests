#!/usr/bin/perl

# (C) Nginx, Inc.

# Tests for QUIC ACK ranges.

###############################################################################

use warnings;
use strict;

use Test::More;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;
use Test::Nginx::HTTP3;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/http http_v3 cryptx/)
	->has_daemon('openssl')->plan(6)
	->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    ssl_certificate_key localhost.key;
    ssl_certificate localhost.crt;

    server {
        listen       127.0.0.1:%%PORT_8980_UDP%% quic;
        server_name  localhost;
    }
}

EOF

$t->write_file('openssl.conf', <<EOF);
[ req ]
default_bits = 2048
encrypt_key = no
distinguished_name = req_distinguished_name
[ req_distinguished_name ]
EOF

my $d = $t->testdir();

foreach my $name ('localhost') {
	system('openssl req -x509 -new '
		. "-config $d/openssl.conf -subj /CN=$name/ "
		. "-out $d/$name.crt -keyout $d/$name.key "
		. ">>$d/openssl.out 2>&1") == 0
		or die "Can't create certificate for $name: $!\n";
}

$t->run();

###############################################################################

is(ack(0, 2, 4, 6, 3, 5), '0 2 3 4 5 6', 'gap filled');
is(ack(0, 4, 8, 1, 3, 7), '0 1 3 4 7 8', 'gap reduced');
is(ack(0, 4, 2), '0 2 4', 'gap split');
is(ack(4, 3, 1, 0), '0 1 3 4', 'range below');
is(ack(1, 3, 5, 7, 9, 11, 13, 15, 17, 19, 21, 23, 0),
	'0 1 3 5 7 9 11 13 15 17 19 21 23', 'ranges full, too old');

local $TODO = 'not yet' unless $t->has_version('1.31.9');

is(ack(0, 5, 7, 9, 11, 13, 15, 17, 19, 21, 23, 3, 25),
	'0 3 5 7 9 11 13 15 17 19 21 23 25', 'ranges full, gap split');

###############################################################################

sub ack {
	my (@pn) = @_;
	my ($max) = sort { $b <=> $a } @pn;

	my $s = Test::Nginx::HTTP3->new(8980, probe => 1, start_chain => 1);
	$s->{send_ack} = 0;
	$s->handshake();

	$s->{socket}->syswrite(join '',
		map { $s->encrypt_aead("\x01", 2, $_) } @pn);

	while (!$s->{acked}[2]{$max}) {
		last unless @{$s->read(all => [{ type => 'ACK' }])};
	}

	return join ' ', sort { $a <=> $b } keys %{$s->{acked}[2]};
}

###############################################################################
