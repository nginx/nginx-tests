#!/usr/bin/perl

# Tests for HTTP/3 protocol with server_header directive.

use warnings;
use strict;

use Test::More;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;
use Test::Nginx::HTTP3;

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()
    ->has(qw/http http_v3 rewrite cryptx/)
    ->has_daemon('openssl')
    ->plan(3);

$t->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    ssl_certificate_key localhost.key;
    ssl_certificate localhost.crt;

    server_header off;

    server {
        listen       127.0.0.1:%%PORT_8980_UDP%% quic;
        server_name  localhost;

        location /default {
            return 200;
        }

        location /on {
            server_header on;
            return 200;
        }

        location /off {
            server_header off;
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

is(header_server('/default'), undef,
    'http3 server header disabled by http directive');

like(header_server('/on'), qr/^nginx(?:\/|$)/,
    'http3 server header enabled in location');

is(header_server('/off'), undef,
    'http3 server header disabled in location');

sub header_server {
    my ($path) = @_;

    my $s = Test::Nginx::HTTP3->new();
    my $sid = $s->new_stream({ path => $path });
    my $frames = $s->read(all => [{ sid => $sid, fin => 1 }]);

    my ($frame) = grep { $_->{type} eq 'HEADERS' } @$frames;

    return $frame->{headers}->{'server'};
}
