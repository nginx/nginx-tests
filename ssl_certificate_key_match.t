#!/usr/bin/perl

# (C) Y.Horie
# (C) Nginx, Inc.

# Tests for http ssl module, certificates without a matching private key.

###############################################################################

use warnings;
use strict;

use Test::More;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/http http_ssl socket_ssl/)
	->has_daemon('openssl');

plan(skip_all => 'no multiple certificates') if $t->has_module('BoringSSL');

$t->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    ssl_ciphers DEFAULT:ECCdraft;

    # keys before certificates, directive order is not significant

    server {
        listen       127.0.0.1:8443 ssl;
        server_name  localhost;

        ssl_certificate_key ec.key;
        ssl_certificate_key rsa.key;
        ssl_certificate rsa.crt;
        ssl_certificate ec.crt;
    }

    # every positional pair crossed, the set is complete

    server {
        listen       127.0.0.1:8444 ssl;
        server_name  localhost;

        ssl_certificate ec.crt;
        ssl_certificate_key rsa.key;
        ssl_certificate rsa.crt;
        ssl_certificate_key ec.key;
    }

    # surplus keys are not loaded: a missing file is not opened

    server {
        listen       127.0.0.1:8445 ssl;
        server_name  localhost;

        ssl_certificate rsa.crt;
        ssl_certificate_key rsa.key;
        ssl_certificate_key nonexistent.key;
    }

    # an existing file with no valid key is not parsed

    server {
        listen       127.0.0.1:8446 ssl;
        server_name  localhost;

        ssl_certificate rsa.crt;
        ssl_certificate_key rsa.key;
        ssl_certificate_key garbage.key;
    }

    # a valid key without a certificate is not loaded

    server {
        listen       127.0.0.1:8447 ssl;
        server_name  localhost;

        ssl_certificate rsa.crt;
        ssl_certificate_key rsa.key;
        ssl_certificate_key ec.key;
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

$t->write_file('garbage.key', 'garbage');

my $d = $t->testdir();

system("openssl ecparam -genkey -out $d/ec.key -name prime256v1 "
	. ">>$d/openssl.out 2>&1") == 0 or die "Can't create EC pem: $!\n";

foreach my $name ('rsa', 'rsa2') {
	system("openssl genrsa -out $d/$name.key 2048 >>$d/openssl.out 2>&1")
		== 0 or die "Can't create RSA pem: $!\n";
}

foreach my $name ('ec', 'rsa', 'rsa2') {
	system("openssl req -x509 -new -key $d/$name.key "
		. "-config $d/openssl.conf -subj /CN=$name/ "
		. "-out $d/$name.crt -keyout $d/$name.key "
		. ">>$d/openssl.out 2>&1") == 0
		or die "Can't create certificate for $name: $!\n";
}

$t->run()->plan(13);

###############################################################################

like(cert(8443, 'RSA'), qr/CN=rsa/, 'keys first RSA');
like(cert(8443, 'ECDSA'), qr/CN=ec/, 'keys first ECDSA');
like(cert(8444, 'RSA'), qr/CN=rsa/, 'crossed pairs RSA');
like(cert(8444, 'ECDSA'), qr/CN=ec/, 'crossed pairs ECDSA');
like(cert(8445, 'RSA'), qr/CN=rsa/, 'surplus key missing');
like(cert(8446, 'RSA'), qr/CN=rsa/, 'surplus key unparsable');
like(cert(8447, 'RSA'), qr/CN=rsa/, 'surplus key valid');

# certificates without a matching key are rejected on reload,
# the previous configuration keeps working

TODO: {
local $TODO = 'not yet' unless $t->has_version('1.31.7');

like(reload($t, <<'EOF'), qr/"[^"]*rsa\.crt" does not match/,
        ssl_certificate rsa.crt;
        ssl_certificate_key ec.key;
EOF
	'key of another type');

like(reload($t, <<'EOF'), qr/"[^"]*rsa2\.crt" does not match/,
        ssl_certificate rsa.crt;
        ssl_certificate_key rsa.key;
        ssl_certificate rsa2.crt;
        ssl_certificate_key ec.key;
EOF
	'second certificate without key');

like(cert(8443, 'RSA'), qr/CN=rsa/, 'previous configuration RSA');
like(cert(8443, 'ECDSA'), qr/CN=ec/, 'previous configuration ECDSA');

}

is(reload($t, <<'EOF'), '', 'matching pairs');
        ssl_certificate rsa.crt;
        ssl_certificate_key rsa.key;
        ssl_certificate rsa2.crt;
        ssl_certificate_key rsa2.key;
        ssl_certificate_key ec.key;
EOF

like(cert(8443, 'RSA'), qr/CN=rsa2/, 'matching pairs RSA');

###############################################################################

sub reload {
	my ($t, $certs) = @_;

	my $re = qr/does not match|exited with code/;
	my $n = () = $t->read_file('error.log') =~ /$re/g;

	$t->write_file_expand('nginx.conf', <<EOF);

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    ssl_ciphers DEFAULT:ECCdraft;

    server {
        listen       127.0.0.1:8443 ssl;
        server_name  localhost;

$certs
    }
}

EOF

	$t->reload();

	my @lines;

	for (1 .. 100) {
		@lines = $t->read_file('error.log') =~ /^(.*(?:$re).*)$/gm;
		last if @lines > $n;
		select undef, undef, undef, 0.1;
	}

	return join "\n", grep { /\[emerg\]/ } @lines[$n .. $#lines];
}

sub cert {
	my $s = get_socket(@_) || return;
	return $s->dump_peer_certificate();
}

sub get_socket {
	my ($port, $type) = @_;

	my $ctx_cb = sub {
		my $ctx = shift;
		return unless defined $type;
		my $ssleay = Net::SSLeay::SSLeay();
		return if ($ssleay < 0x1000200f || $ssleay == 0x20000000);
		my @sigalgs = ('RSA+SHA256:PSS+SHA256', 'RSA+SHA256');
		@sigalgs = ($type . '+SHA256') unless $type eq 'RSA';
		# SSL_CTRL_SET_SIGALGS_LIST
		Net::SSLeay::CTX_ctrl($ctx, 98, 0, $sigalgs[0])
			or Net::SSLeay::CTX_ctrl($ctx, 98, 0, $sigalgs[1])
			or die("Failed to set sigalgs");
	};

	return http(
		'', start => 1,
		PeerAddr => '127.0.0.1:' . port($port),
		SSL => 1,
		SSL_cipher_list => $type,
		SSL_create_ctx_callback => $ctx_cb
	);
}

###############################################################################
