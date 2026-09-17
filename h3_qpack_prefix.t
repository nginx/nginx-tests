#!/usr/bin/perl

# (C) Daniel Carlier

# Tests for HTTP/3 QPACK field section prefix validation.

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

        location / {
            return 200;
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

$t->run();

###############################################################################

my ($s, $sid, $frames, $frame);

# baseline: normal request works

$s = Test::Nginx::HTTP3->new();
$sid = $s->new_stream({ path => '/' });
$frames = $s->read(all => [{ sid => $sid, fin => 1 }]);

($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
is($frame->{headers}->{':status'}, 200, 'normal request');

# field section prefix with oversized delta_base (value 2^32)
# followed by a post-base indexed field reference (index 0)
# which forces the decoder to use base for a dynamic table lookup
#
# On 32-bit: triggers truncation check (pint.value > ngx_uint_t max)
# On 64-bit: lookup at base + 0 = 2^32 fails dynamic table bounds check

$sid = $s->new_stream({ headers => [
	{ name => ':method', value => 'GET', mode => 0 },
	{ name => ':scheme', value => 'http', mode => 0 },
	{ name => ':path', value => '/', mode => 0 },
	{ name => ':authority', value => 'localhost', mode => 4 }],
	raw_prefix => pack("C*", 0x00, 0x7F, 0x81, 0xFF, 0xFF, 0xFF, 0x0F)
		. pack("C", 0x10) });
$frames = $s->read(all => [{ type => 'RESET_STREAM' }], wait => 2);

($frame) = grep { $_->{type} eq "RESET_STREAM" } @$frames;
ok($frame, 'oversized delta_base - stream reset');

###############################################################################
