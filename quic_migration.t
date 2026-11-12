#!/usr/bin/perl

# (C) Sergey Kandaurov
# (C) Nginx, Inc.

# Tests for quic connection migration.

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
	->has_daemon('openssl')->plan(9);

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

        location / {
            add_header X-IP $remote_addr;
        }

        location /only20 {
            allow 127.0.0.20;
            deny all;
        }
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
$t->write_file('only20', '');
$t->run();

###############################################################################

# test that $remote_addr is not truncated after migration (ticket #2488),
# to test, we migrate to another address large enough in text representation,
# then send a request on the new path

my $s = Test::Nginx::HTTP3->new();
$s->new_connection_id(1, 0, "connection_id_1", "reset_token_0001");

my $frames = $s->read(all => [{ type => 'NCID' }]);
my ($frame) = grep { $_->{type} eq "NCID" } @$frames;

$s->{socket} = IO::Socket::INET->new(
	Proto => "udp",
	LocalAddr => '127.0.0.20',
	PeerAddr => '127.0.0.1:' . port(8980),
);
$s->{scid} = "connection_id_1";
$s->{dcid} = $frame->{cid};
$s->ping();

$frames = $s->read(all => [{ type => 'PATH_CHALLENGE' }]);
($frame) = grep { $_->{type} eq "PATH_CHALLENGE" } @$frames;
$s->path_response($frame->{data});

$frames = $s->read(all => [{ sid => $s->new_stream(), fin => 1 }]);
($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
is($frame->{headers}{'x-ip'}, '127.0.0.20', 'remote addr after migration');

$frames = $s->read(all => [{ sid => $s->new_stream(), fin => 1 }]);
($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
is($frame->{headers}{'x-ip'}, '127.0.0.20', 'next packets after migration');

# test that $remote_addr is not truncated while in the process of migration;
# the same but migration occurs on receiving a request stream itself,
# which is the first non-probing frame on the new path;
# this might lead to $remote_addr truncation in the following order:
# - stream held original sockaddr/addr_text references on stream creation
# - values were rewritten as part of handling connection migration
# - stream was handled referencing rewritten values, with old local lengths
# sockaddr and addr_text are expected to keep copies on stream creation

$s = Test::Nginx::HTTP3->new();
$s->new_connection_id(1, 0, "connection_id_1", "reset_token_0001");

$frames = $s->read(all => [{ type => 'NCID' }]);
($frame) = grep { $_->{type} eq "NCID" } @$frames;

$s->{socket} = IO::Socket::INET->new(
	Proto => "udp",
	LocalAddr => '127.0.0.20',
	PeerAddr => '127.0.0.1:' . port(8980),
);
$s->{scid} = "connection_id_1";
$s->{dcid} = $frame->{cid};

my $sid = $s->new_stream();

$frames = $s->read(all => [{ type => 'PATH_CHALLENGE' }]);
($frame) = grep { $_->{type} eq "PATH_CHALLENGE" } @$frames;
$s->path_response($frame->{data});

$frames = $s->read(all => [{ sid => $sid, fin => 1 }]);
($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
is($frame->{headers}{'x-ip'}, '127.0.0.1', 'remote addr on migration');

###############################################################################

# test that a NEW_CONNECTION_ID frame, which arrives from a new client
# address and retires the client id nginx has just bound to that address,
# does not leave the retired path in use: no PATH_RESPONSE is sent on it,
# migration does not proceed onto it, and the next non-probing packet from
# the new address migrates normally

$s = Test::Nginx::HTTP3->new();
$s->new_connection_id(1, 0, "connection_id_1", "reset_token_0001");

$frames = $s->read(all => [{ type => 'NCID' }]);
($frame) = grep { $_->{type} eq "NCID" } @$frames;

my $sock1 = $s->{socket};
my $sock20 = IO::Socket::INET->new(
	Proto => "udp",
	LocalAddr => '127.0.0.20',
	PeerAddr => '127.0.0.1:' . port(8980),
);
$s->{socket} = $sock20;
$s->{scid} = "connection_id_1";
$s->{dcid} = $frame->{cid};

# seq 2 with retire prior to 2 retires seq 0 (the active path, re-keyed to
# seq 2) and seq 1 (the path this packet has just created); then
# PATH_CHALLENGE and PING

$s->start_chain();
$s->new_connection_id(2, 2, "connection_id_2", "reset_token_0002");
$s->path_challenge("challeng");
$s->ping(3, 1);
$s->send_chain();

$frames = $s->read(all => [{ type => 'PATH_CHALLENGE' }], wait => 1);
my @resp = grep { $_->{type} eq "PATH_RESPONSE" } @$frames;
my @chal = grep { $_->{type} eq "PATH_CHALLENGE" } @$frames;

TODO: {
local $TODO = 'not yet' unless $t->has_version('1.31.10');

is(scalar @resp, 0, 'no PATH_RESPONSE on the retired path');
is(scalar @chal, 0, 'no migration onto the retired path');

}

# seq 2 replaced seq 0 on the active path and seq 1 is retired, so no id
# is spare for the new address at the default active_connection_id_limit
# of 2; supply seq 3 on the original path, then move again

$s->{socket} = $sock1;
$s->new_connection_id(3, 0, "connection_id_3", "reset_token_0003");
$s->read(all => [{ type => 'ACK' }], wait => 1);

$s->{socket} = $sock20;
$s->ping();

$frames = $s->read(all => [{ type => 'PATH_CHALLENGE' }], wait => 2);
for my $f (grep { $_->{type} eq "PATH_CHALLENGE" } @$frames) {
	$s->path_response($f->{data});
}

TODO: {
local $TODO = 'not yet' unless $t->has_version('1.31.10');

$frames = $s->read(all => [{ sid => $s->new_stream(), fin => 1 }]);
($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
is($frame->{headers}{'x-ip'}, '127.0.0.20', 'remote addr after retire');

$frames = $s->read(all => [{ sid => $s->new_stream({ path => '/only20' }),
	fin => 1 }]);
($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
is($frame->{headers}{':status'}, 200, 'allow by migrated address');

$frames = $s->read(all => [{ sid => $s->new_stream(), fin => 1 }]);
($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
is($frame->{headers}{'x-ip'}, '127.0.0.20', 'next request after retire');

$frames = $s->read(all => [{ sid => $s->new_stream(), fin => 1 }]);
($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
is($frame->{headers}{'x-ip'}, '127.0.0.20', 'remote addr stable');

}

###############################################################################
