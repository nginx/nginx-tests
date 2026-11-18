#!/usr/bin/perl

# (C) Vadim Zhestikov
# (C) Nginx, Inc.

# Tests for QUIC NAT rebinding with no unused client connection id.

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

plan(skip_all => '127.0.0.20 local address required')
	unless defined IO::Socket::INET->new( LocalAddr => '127.0.0.20' );
plan(skip_all => '127.0.0.30 local address required')
	unless defined IO::Socket::INET->new( LocalAddr => '127.0.0.30' );

my $t = Test::Nginx->new()->has(qw/http http_v3 cryptx/)
	->has_daemon('openssl')->plan(3);

$t->write_file_expand('nginx.conf', <<'EOF');

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

        add_header X-IP $remote_addr;
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

$t->write_file('index.html', '');
$t->run();

###############################################################################

# On NAT rebinding the client keeps the connection id and its address changes.
# With the default active_connection_id_limit of 2, the active and the backup
# paths held both client ids after the first rebinding, so packets from the
# next address were dropped.  The previous address does not answer.

my $s = Test::Nginx::HTTP3->new();

# one spare client connection id, of the same length as the initial one
$s->new_connection_id(1, 0, "connection_id_abc", "reset_token_0001");
$s->read(all => [{ type => 'NCID' }]);

is(rebind($s, '127.0.0.20'), '127.0.0.20', 'rebinding');

TODO: {
local $TODO = 'not yet' unless $t->has_version('1.31.10');

is(rebind($s, '127.0.0.30'), '127.0.0.30', 'repeated rebinding');

}

undef $s;

# a client which provides no spare connection ids

$s = Test::Nginx::HTTP3->new();
$s->read(all => [{ type => 'NCID' }]);

TODO: {
local $TODO = 'not yet' unless $t->has_version('1.31.10');

is(rebind($s, '127.0.0.20'), '127.0.0.20', 'rebinding without spare ids');

}

###############################################################################

sub rebind {
	my ($s, $addr) = @_;

	$s->{socket} = IO::Socket::INET->new(
		Proto => "udp",
		LocalAddr => $addr,
		PeerAddr => '127.0.0.1:' . port(8980));

	# a full-size packet lets the server send a full-size PATH_CHALLENGE,
	# so the new path is validated in one round

	$s->{frames_in} = [];
	$s->ping(3, 1200);

	my $frames = $s->read(all => [{ type => 'PATH_CHALLENGE' }], wait => 1);
	my ($frame) = grep { $_->{type} eq "PATH_CHALLENGE" } @$frames;
	return 'no challenge' unless $frame;

	$s->path_response($frame->{data});
	$s->read(all => [{ type => 'NEW_TOKEN' }]);

	$frames = $s->read(all => [{ sid => $s->new_stream(), fin => 1 }]);
	($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
	return $frame->{headers}{'x-ip'};
}

###############################################################################
