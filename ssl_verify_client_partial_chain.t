#!/usr/bin/perl

# (C) Nginx, Inc.

# Tests for http ssl module, ssl_verify_client partial_chain.
#
# Validates that ssl_verify_client partial_chain accepts a client certificate
# whose chain terminates at a trusted intermediate CA, without requiring the
# full chain of trust up to a root CA.

###############################################################################

use warnings;
use strict;

use Test::More;

use Socket qw/ CRLF /;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx qw/ :DEFAULT /;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/http http_ssl socket_ssl/)
	->has_daemon('openssl')->plan(7);

$t->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    ssl_certificate     localhost.crt;
    ssl_certificate_key localhost.key;

    add_header X-Verify $ssl_client_verify always;

    # partial_chain: accepts leaf cert signed by trusted intermediate,
    # root CA is not in the bundle and not required
    server {
        listen       127.0.0.1:8080 ssl;
        server_name  localhost;

        ssl_verify_client    partial_chain;
        ssl_client_certificate int.crt;
    }

    # control: same intermediate-only bundle but regular "on" mode;
    # leaf cert must fail because root CA is absent from the store
    server {
        listen       127.0.0.1:8081 ssl;
        server_name  localhost;

        ssl_verify_client    on;
        ssl_client_certificate int.crt;
    }

    # partial_chain via ssl_trusted_certificate (not ssl_client_certificate)
    server {
        listen       127.0.0.1:8082 ssl;
        server_name  localhost;

        ssl_verify_client       partial_chain;
        ssl_trusted_certificate int.crt;
    }
}

EOF

my $d = $t->testdir();

$t->write_file('openssl.conf', <<EOF);
[ req ]
default_bits = 2048
encrypt_key = no
distinguished_name = req_distinguished_name
x509_extensions = myca_extensions
[ req_distinguished_name ]
[ myca_extensions ]
basicConstraints = critical,CA:TRUE
EOF

$t->write_file('ca.conf', <<EOF);
[ ca ]
default_ca = myca

[ myca ]
new_certs_dir = $d
database      = $d/certindex
default_md    = sha256
policy        = myca_policy
serial        = $d/certserial
default_days  = 3
x509_extensions = client_extensions

[ myca_policy ]
commonName = supplied

[ myca_extensions ]
basicConstraints = critical,CA:TRUE

[ client_extensions ]
basicConstraints = CA:FALSE
extendedKeyUsage = clientAuth
EOF

# self-signed server certificate
system('openssl req -x509 -new '
	. "-config $d/openssl.conf -subj /CN=localhost/ "
	. "-out $d/localhost.crt -keyout $d/localhost.key "
	. ">>$d/openssl.out 2>&1") == 0
	or die "Can't create localhost certificate: $!\n";

# root CA (self-signed) - intentionally NOT added to nginx trust store
system('openssl req -x509 -new '
	. "-config $d/openssl.conf -subj /CN=root/ "
	. "-out $d/root.crt -keyout $d/root.key "
	. ">>$d/openssl.out 2>&1") == 0
	or die "Can't create root certificate: $!\n";

# intermediate CA and leaf CSRs
foreach my $name ('int', 'end') {
	system('openssl req -new '
		. "-config $d/openssl.conf -subj /CN=$name/ "
		. "-out $d/$name.csr -keyout $d/$name.key "
		. ">>$d/openssl.out 2>&1") == 0
		or die "Can't create CSR for $name: $!\n";
}

# unrelated self-signed cert (not in any chain)
system('openssl req -x509 -new '
	. "-config $d/openssl.conf -subj /CN=other/ "
	. "-out $d/other.crt -keyout $d/other.key "
	. ">>$d/openssl.out 2>&1") == 0
	or die "Can't create other certificate: $!\n";

$t->write_file('certserial', '1000');
$t->write_file('certindex', '');

# intermediate CA signed by root
system("openssl ca -batch -config $d/ca.conf "
	. "-keyfile $d/root.key -cert $d/root.crt "
	. "-extensions myca_extensions "
	. "-subj /CN=int/ -in $d/int.csr -out $d/int.crt "
	. ">>$d/openssl.out 2>&1") == 0
	or die "Can't sign intermediate certificate: $!\n";

# leaf cert signed by intermediate (has clientAuth extension)
system("openssl ca -batch -config $d/ca.conf "
	. "-keyfile $d/int.key -cert $d/int.crt "
	. "-extensions client_extensions "
	. "-subj /CN=end/ -in $d/end.csr -out $d/end.crt "
	. ">>$d/openssl.out 2>&1") == 0
	or die "Can't sign end certificate: $!\n";

$t->write_file('t', '');

$t->run();

###############################################################################

# --- partial_chain via ssl_client_certificate ---

# no cert: partial_chain requires a cert (behaves like "on")
like(get(8080), qr/400 Bad Request/, 'partial_chain - no cert');

# leaf cert signed by trusted intermediate: should be accepted
like(get(8080, 'end'), qr/SUCCESS/, 'partial_chain - leaf cert accepted');

# unrelated self-signed cert: should be rejected
like(get(8080, 'other'), qr/400 Bad Request/, 'partial_chain - unknown cert rejected');

# --- control: regular "on" with same intermediate-only bundle ---

# leaf cert fails with regular "on" because root CA is not trusted
like(get(8081, 'end'), qr/400 Bad Request/,
	'on (control) - leaf cert rejected without root CA');

# --- partial_chain via ssl_trusted_certificate ---

# leaf cert signed by trusted intermediate: should be accepted
like(get(8082, 'end'), qr/SUCCESS/,
	'partial_chain trusted_certificate - leaf cert accepted');

# no cert: partial_chain requires a cert
like(get(8082), qr/400 Bad Request/,
	'partial_chain trusted_certificate - no cert');

# unrelated cert: should be rejected
like(get(8082, 'other'), qr/400 Bad Request/,
	'partial_chain trusted_certificate - unknown cert rejected');

###############################################################################

sub get {
	my ($port, $cert) = @_;
	http_get(
		'/t',
		PeerAddr => '127.0.0.1:' . port($port),
		SSL => 1,
		$cert ? (
		SSL_cert_file => "$d/$cert.crt",
		SSL_key_file  => "$d/$cert.key",
		) : ()
	);
}

###############################################################################

