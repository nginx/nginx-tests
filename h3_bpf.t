#!/usr/bin/perl

# (C) Sai Krishna Kumar Reddy YADAMAKANTI
# (C) Nginx, Inc.

# Tests for HTTP/3 with quic_bpf.

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

plan(skip_all => 'linux only test') if $^O ne 'linux';
plan(skip_all => 'must be root') if $> != 0;

my $t = Test::Nginx->new({ can_root => 1 })
	->has(qw/http http_ssl http_v3 cryptx/)
	->has_daemon('openssl')->plan(4)
	->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

worker_processes 2;

events {
}

quic_bpf on;

http {
    %%TEST_GLOBALS_HTTP%%

    ssl_certificate_key localhost.key;
    ssl_certificate localhost.crt;

    server {
        listen       127.0.0.1:%%PORT_8980_UDP%% quic reuseport;
        server_name  test.example.com;

        location / {
            return 200 "$pid";
        }
    }
}

EOF

$t->write_file('openssl.conf', <<'EOF');
[ req ]
default_bits = 2048
encrypt_key = no
distinguished_name = req_distinguished_name
[ req_distinguished_name ]
EOF

my $d = $t->testdir();

system('openssl req -x509 -new '
	. "-config $d/openssl.conf -subj /CN=test.example.com/ "
	. "-out $d/localhost.crt -keyout $d/localhost.key "
	. ">>$d/openssl.out 2>&1") == 0
	or die "Can't create certificate for test.example.com: $!\n";

$t->run();

###############################################################################

my $port = 9000;
my $s = Test::Nginx::HTTP3->new(8980, local_addr => '127.0.0.1',
	local_port => $port, sni => 'test.example.com');
my $sid = $s->new_stream({ body_more => 1, headers => [
	{ name => ':method', value => 'GET' },
	{ name => ':scheme', value => 'https' },
	{ name => ':path', value => '/' },
	{ name => ':authority', value => 'test.example.com' },
]});

ok(defined $sid, 'initial HTTP/3 stream created');
ok($t->reload(), 'reload');

$s->h3_body('', $sid, {});
my $frames = $s->read(all => [{ sid => $sid, fin => 1 }]);
my ($frame) = grep { $_->{type} eq 'HEADERS' } @$frames;
is($frame->{headers}->{':status'}, 200,
	'established connection routes by DCID after reload');

$s->{socket}->close();

$s = Test::Nginx::HTTP3->new(8980, local_addr => '127.0.0.1',
	local_port => $port, sni => 'test.example.com');
$sid = $s->new_stream({ path => '/' });
$frames = $s->read(all => [{ sid => $sid, fin => 1 }]);
($frame) = grep { $_->{type} eq 'HEADERS' } @$frames;
is($frame->{headers}->{':status'}, 200,
	'new connection routes after reload');

###############################################################################
