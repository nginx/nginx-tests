#!/usr/bin/perl

# (C) Nginx, Inc.

# Tests for QUIC ACK frames.

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
	->has_daemon('openssl')->plan(2)
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

        location / { }
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

$t->write_file('index.html', 'SEE-THIS');

$t->run();

###############################################################################

my ($s, $sid, $frames, $frame);

# ACK frames of type 0x03 carry ECN counts and must be accepted
# (RFC 9000, 19.3.2)

local $TODO = 'not yet' unless $t->has_version('1.31.9');

$s = Test::Nginx::HTTP3->new(8980, ack_ecn => 1);
$sid = $s->new_stream({ path => '/' });
$frames = $s->read(all => [{ sid => $sid, fin => 1 }]);

($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
is($frame->{headers}->{':status'}, 200, 'ACK ECN - status');

($frame) = grep { $_->{type} eq "DATA" } @$frames;
is($frame->{data}, 'SEE-THIS', 'ACK ECN - body');

###############################################################################
