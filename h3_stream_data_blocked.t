#!/usr/bin/perl

# (C) Vadim Zhestikov
# (C) Nginx, Inc.

# Tests for QUIC STREAM_DATA_BLOCKED and DATA_BLOCKED frames
# (RFC 9000, Section 4.1).

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

$t->write_file('big', 'X' x 65536);
$t->run();

###############################################################################

# stream-level: small stream flow control window, ample connection window

my $s = Test::Nginx::HTTP3->new(8980, opts => { 5 => 4096 });
my $sid = $s->new_stream({ path => '/big' });

my $frames = $s->read(all => [{ type => 'STREAM_DATA_BLOCKED' }]);
my ($frame) = grep { $_->{type} eq 'STREAM_DATA_BLOCKED' } @$frames;

ok($frame, 'stream data blocked - frame');
is($frame->{sid}, $sid, 'stream data blocked - stream id');
is($frame->{limit}, 4096, 'stream data blocked - limit');

# raising the limit halfway re-arms the signal at the new limit

$s->h3_max_data(8192, $sid);

$frames = $s->read(all => [{ type => 'STREAM_DATA_BLOCKED' }]);
($frame) = grep { $_->{type} eq 'STREAM_DATA_BLOCKED' } @$frames;

ok($frame, 'stream data blocked - new frame after limit update');
is($frame->{limit}, 8192, 'stream data blocked - updated limit');

# raising the limit past the response size unblocks the transfer

$s->h3_max_data(1024 * 1024, $sid);

$frames = $s->read(all => [{ sid => $sid, fin => 1 }]);
my $body = join '', map { $_->{data} } grep { $_->{type} eq "DATA" } @$frames;

is(length($body), 65536, 'stream data blocked - transfer completes');

###############################################################################

# connection-level: small connection window, ample stream window

$s = Test::Nginx::HTTP3->new(8980, opts => { 4 => 4096 });
$sid = $s->new_stream({ path => '/big' });

$frames = $s->read(all => [{ type => 'DATA_BLOCKED' }]);
($frame) = grep { $_->{type} eq 'DATA_BLOCKED' } @$frames;

ok($frame, 'data blocked - frame');
is($frame->{limit}, 4096, 'data blocked - limit');

$s->h3_max_data(1024 * 1024);

$frames = $s->read(all => [{ sid => $sid, fin => 1 }]);
$body = join '', map { $_->{data} } grep { $_->{type} eq "DATA" } @$frames;

is(length($body), 65536, 'data blocked - transfer completes');

###############################################################################
