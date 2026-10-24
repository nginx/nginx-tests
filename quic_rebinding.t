#!/usr/bin/perl

# (C) Vadim Zhestikov
# (C) Nginx, Inc.

# Tests for QUIC connection migration on NAT rebinding.

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

my $t = Test::Nginx->new()->has(qw/http http_v3 cryptx/)
	->has_daemon('openssl')->plan(2);

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

# On NAT rebinding the client keeps the connection id and moves to a new
# address.  The server validates the new path and the previous one, which
# becomes backup.  A late validation of the backup path used to overwrite the
# connection address, so streams created afterwards were attributed to the
# backup address while packets were exchanged on the new path.

my $s = Test::Nginx::HTTP3->new();

# a client connection id of the same length as the initial one, so packets the
# server sends on the new path, which uses it, keep the short header length
$s->new_connection_id(1, 0, "connection_id_abc", "reset_token_0001");

# consume post-handshake packets on the initial path before rebinding
my $frames = $s->read(all => [{ type => 'NCID' }]);

my $old = $s->{socket};
my $new = IO::Socket::INET->new(
	Proto => "udp",
	LocalAddr => '127.0.0.20',
	PeerAddr => '127.0.0.1:' . port(8980));

$s->{socket} = $new;
$s->ping();

# validate the new path and consume its validation token, so the next token
# belongs to the backup path validation below

$frames = $s->read(all => [{ type => 'PATH_CHALLENGE' }]);
my ($frame) = grep { $_->{type} eq "PATH_CHALLENGE" } @$frames;
$s->path_response($frame->{data});

$s->read(all => [{ type => 'NEW_TOKEN' }]);

$frames = $s->read(all => [{ sid => $s->new_stream(), fin => 1 }]);
($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
is($frame->{headers}{'x-ip'}, '127.0.0.20', 'new path');

# read the backup path challenge; an acknowledgement on the backup path is a
# non-probing frame and would restart migration, so it is withheld

$s->{socket} = $old;
$s->{send_ack} = 0;
$frames = $s->read(all => [{ type => 'PATH_CHALLENGE' }]);
my ($backup) = grep { $_->{type} eq "PATH_CHALLENGE" } @$frames;
$s->path_response($backup->{data});
$s->{send_ack} = 1;

# wait on the new path for the backup path validation token, then send a
# request; it is attributed to the new address, not the backup address

$s->{socket} = $new;
$s->{frames_in} = [];
$s->read(all => [{ type => 'NEW_TOKEN' }]);

$frames = $s->read(all => [{ sid => $s->new_stream(), fin => 1 }]);
($frame) = grep { $_->{type} eq "HEADERS" } @$frames;

# the fix is not in a release yet; once it is, guard with
# $t->has_version() for the release that carries it
TODO: {
local $TODO = 'not yet';

is($frame->{headers}{'x-ip'}, '127.0.0.20', 'new path after backup validation');

}

###############################################################################
