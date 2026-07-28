#!/usr/bin/perl

# (C) Sergey Kandaurov
# (C) Nginx, Inc.

# Tests for QUIC stream final size.

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

my $t = Test::Nginx->new()->has(qw/http http_v3 proxy cryptx/)
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
        listen       127.0.0.1:8080;
        server_name  localhost;

        http3_stream_buffer_size 64k;

        location / {
            proxy_pass http://127.0.0.1:8080/stub;
        }

        location /stub { }
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

# RESET_STREAM frames with same final size

$s = Test::Nginx::HTTP3->new();
$sid = $s->new_stream({ body_more => 1 });
$s->start_chain();
$s->reset_stream($sid, 0x010c);
$s->reset_stream($sid, 0x010c);
$s->send_chain();

$frames = $s->read(all => [{ type => 'RESET_STREAM' }]);
($frame) = grep { $_->{type} eq "RESET_STREAM" } @$frames;
ok($frame, 'reset final size match');

local $TODO = 'not yet' unless $t->has_version('1.31.4');

# RESET_STREAM frames with different final size

$s = Test::Nginx::HTTP3->new();
$sid = $s->new_stream({ body_more => 1 });
$s->start_chain();
$s->reset_stream($sid, 0x010c);
$s->reset_stream($sid, 0x010c, 42);
$s->send_chain();

$frames = $s->read(all => [{ type => 'CONNECTION_CLOSE' }]);
($frame) = grep { $_->{type} eq "CONNECTION_CLOSE" } @$frames;
is($frame->{'error'}, 6, 'reset final size mismatch');

# STREAM fin under the maximum received offset+length

$s = Test::Nginx::HTTP3->new();
$sid = $s->new_stream({ body_more => 1 });
# stream consumption
select undef, undef, undef, 0.2;
$s->h3_body('TEST', $sid, { offset => 42 });

$frames = $s->read(all => [{ type => 'CONNECTION_CLOSE' }]);
($frame) = grep { $_->{type} eq "CONNECTION_CLOSE" } @$frames;
is($frame->{'error'}, 6, 'stream final size too small');

# STREAM fin under final size

$s = Test::Nginx::HTTP3->new();
$sid = $s->new_stream({ body_more => 1 });
$s->start_chain();
$s->reset_stream($sid, 0x010c, 100);
$s->h3_body('TEST', $sid);
$s->send_chain();

$frames = $s->read(all => [{ type => 'CONNECTION_CLOSE' }]);
($frame) = grep { $_->{type} eq "CONNECTION_CLOSE" } @$frames;
is($frame->{'error'}, 6, 'stream final size less');

# STREAM fin beyond final size

$s = Test::Nginx::HTTP3->new();
$sid = $s->new_stream({ body_more => 1 });
$s->start_chain();
$s->reset_stream($sid, 0x010c);
$s->h3_body('TEST', $sid);
$s->send_chain();

$frames = $s->read(all => [{ type => 'CONNECTION_CLOSE' }]);
($frame) = grep { $_->{type} eq "CONNECTION_CLOSE" } @$frames;
is($frame->{'error'}, 6, 'stream final size greater');

# RESET_STREAM flow control

$s = Test::Nginx::HTTP3->new();
$sid = $s->new_stream({ body_more => 1 });
$s->reset_stream($sid, 0x010c, 65 * 1024);

$frames = $s->read(all => [{ type => 'CONNECTION_CLOSE' }]);
($frame) = grep { $_->{type} eq "CONNECTION_CLOSE" } @$frames;
is($frame->{'error'}, 3, 'reset flow control violation');

###############################################################################
