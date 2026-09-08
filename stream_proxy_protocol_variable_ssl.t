#!/usr/bin/perl

# Tests for variable PROXY protocol with TLS upstreams and SSL preread.

###############################################################################

use warnings;
use strict;

use Test::More;
use Socket qw/ CRLF /;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;
use Test::Nginx::Stream qw/ stream /;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/stream stream_ssl stream_ssl_preread
	stream_map stream_return socket_ssl/)->has_daemon('openssl')->plan(6);

$t->write_file_expand('nginx.conf', <<'EOF');
%%TEST_GLOBALS%%

daemon off;

events {
}

stream {
    %%TEST_GLOBALS_STREAM%%

    map $ssl_preread_server_name $preread_protocol {
        on.test     on;
        off.test    off;
        v2.test     v2;
    }

    map $preread_protocol $preread_backend {
        off         127.0.0.1:8082;
        default     127.0.0.1:8081;
    }

    map $proxy_protocol_server_port $pp_version {
        1           on;
        2           off;
        3           v2;
    }

    map $pp_version $backend {
        off         127.0.0.1:8082;
        default     127.0.0.1:8081;
    }

    ssl_certificate localhost.crt;
    ssl_certificate_key localhost.key;

    server {
        listen 127.0.0.1:8080;
        ssl_preread on;
        proxy_pass $preread_backend;
        proxy_protocol $preread_protocol;
    }

    server {
        listen 127.0.0.1:8083 proxy_protocol;
        proxy_pass $backend;
        proxy_ssl on;
        proxy_protocol $pp_version;
    }

    server {
        listen 127.0.0.1:8081 ssl proxy_protocol;
        return "$proxy_protocol_addr:$proxy_protocol_port";
    }

    server {
        listen 127.0.0.1:8082 ssl;
        return "no proxy protocol";
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
	. "-config $d/openssl.conf -subj /CN=localhost/ "
	. "-out $d/localhost.crt -keyout $d/localhost.key "
	. ">>$d/openssl.out 2>&1") == 0
	or die "Can't create certificate: $!\n";

$t->run();

###############################################################################

for my $pp_version ('on', 'off', 'v2') {
	my $s = stream(PeerPort => port(8080), SSL => 1,
		SSL_hostname => "$pp_version.test");
	my $expected = $pp_version eq 'off' ? 'no proxy protocol'
		: '127.0.0.1:' . $s->sockport();

	is($s->io(''), $expected, "SSL preread selects $pp_version");
}

for my $selector (1 .. 3) {
	my $s = stream('127.0.0.1:' . port(8083));
	my $expected = $selector == 2 ? 'no proxy protocol'
		: '127.0.0.1:' . $s->sockport();

	is($s->io("PROXY TCP4 192.0.2.1 192.0.2.2 12345 $selector" . CRLF),
		$expected, "proxy_ssl protocol $selector");
}

###############################################################################
