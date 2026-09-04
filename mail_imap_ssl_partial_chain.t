#!/usr/bin/perl

# (C) Nginx, Inc.

# Tests for nginx mail imap module with ssl_verify_partial_chain.

###############################################################################

use warnings;
use strict;

use Test::More;

use MIME::Base64;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;
use Test::Nginx::IMAP;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

local $SIG{PIPE} = 'IGNORE';

my $t = Test::Nginx->new()
	->has(qw/mail mail_ssl imap http rewrite socket_ssl_sslversion/)
	->has_daemon('openssl')->plan(12)
	->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

mail {
    proxy_pass_error_message  on;
    proxy_timeout  15s;
    auth_http  http://127.0.0.1:18083/mail/auth;
    auth_http_pass_client_cert on;

    ssl_certificate_key localhost.key;
    ssl_certificate localhost.crt;

    server {
        listen     127.0.0.1:18080 ssl;
        protocol   imap;

        ssl_verify_client    on;
        ssl_verify_partial_chain on;
        ssl_client_certificate int.crt;
    }

    server {
        listen     127.0.0.1:18081 ssl;
        protocol   imap;

        ssl_verify_client    on;
        ssl_client_certificate int.crt;
    }

    server {
        listen     127.0.0.1:18082 ssl;
        protocol   imap;

        ssl_verify_client       on;
        ssl_verify_partial_chain on;
        ssl_trusted_certificate int.crt;
    }

    server {
        listen     127.0.0.1:18085 ssl;
        protocol   imap;

        ssl_verify_client    optional;
        ssl_verify_partial_chain on;
        ssl_client_certificate int.crt;
    }
}

http {
    %%TEST_GLOBALS_HTTP%%

    log_format test '$http_auth_ssl_verify:$http_auth_ssl_subject:'
                    '$http_auth_pass';

    server {
        listen       127.0.0.1:18083;
        server_name  localhost;

        location = /mail/auth {
            access_log auth.log test;

            add_header Auth-Status OK;
            add_header Auth-Server 127.0.0.1;
            add_header Auth-Port 18084;
            add_header Auth-Wait 1;
            return 204;
        }
    }
}

EOF

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

my $d = $t->testdir();

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

sub openssl {
	system("$_[0] >>$d/openssl.out 2>&1") == 0
		or die "openssl command failed: $_[0]\n";
}

openssl("openssl req -x509 -new "
	. "-config $d/openssl.conf -subj /CN=localhost/ "
	. "-out $d/localhost.crt -keyout $d/localhost.key");

openssl("openssl req -x509 -new "
	. "-config $d/openssl.conf -subj /CN=root/ "
	. "-out $d/root.crt -keyout $d/root.key");

foreach my $name ('int', 'end') {
	openssl("openssl req -new "
		. "-config $d/openssl.conf -subj /CN=$name/ "
		. "-out $d/$name.csr -keyout $d/$name.key");
}

openssl("openssl req -x509 -new "
	. "-config $d/openssl.conf -subj /CN=other/ "
	. "-out $d/other.crt -keyout $d/other.key");

$t->write_file('certserial', '1000');
$t->write_file('certindex', '');

openssl("openssl ca -batch -config $d/ca.conf "
	. "-keyfile $d/root.key -cert $d/root.crt "
	. "-extensions myca_extensions "
	. "-subj /CN=int/ -in $d/int.csr -out $d/int.crt");

openssl("openssl ca -batch -config $d/ca.conf "
	. "-keyfile $d/int.key -cert $d/int.crt "
	. "-extensions client_extensions "
	. "-subj /CN=end/ -in $d/end.csr -out $d/end.crt");

$t->run_daemon(\&Test::Nginx::IMAP::imap_test_daemon, 18084);
$t->run()->waitforsocket('127.0.0.1:18084');

###############################################################################

my $cred = sub { encode_base64("\0test\@example.com\0$_[0]", '') };

my $s = Test::Nginx::IMAP->new(PeerAddr => '127.0.0.1:18080', SSL => 1);
$s->check(qr/BYE No required SSL certificate/, 'partial_chain - no cert');

$s = Test::Nginx::IMAP->new(
	PeerAddr => '127.0.0.1:18080',
	SSL => 1,
	SSL_cert_file => "$d/end.crt",
	SSL_key_file => "$d/end.key"
);
$s->ok('partial_chain - leaf cert accepted');
$s->send('1 AUTHENTICATE PLAIN ' . $cred->("p1"));

$s = Test::Nginx::IMAP->new(
	PeerAddr => '127.0.0.1:18080',
	SSL => 1,
	SSL_cert_file => "$d/other.crt",
	SSL_key_file => "$d/other.key"
);
$s->check(qr/BYE SSL certificate error/, 'partial_chain - unknown cert rejected');

$s = Test::Nginx::IMAP->new(
	PeerAddr => '127.0.0.1:18081',
	SSL => 1,
	SSL_cert_file => "$d/end.crt",
	SSL_key_file => "$d/end.key"
);
$s->check(qr/BYE SSL certificate error/,
	'on \(control\) - leaf cert rejected without root CA');

$s = Test::Nginx::IMAP->new(
	PeerAddr => '127.0.0.1:18082',
	SSL => 1,
	SSL_cert_file => "$d/end.crt",
	SSL_key_file => "$d/end.key"
);
$s->ok('partial_chain trusted_certificate - leaf cert accepted');
$s->send('1 AUTHENTICATE PLAIN ' . $cred->("p2"));

$s = Test::Nginx::IMAP->new(PeerAddr => '127.0.0.1:18082', SSL => 1);
$s->check(qr/BYE No required SSL certificate/,
	'partial_chain trusted_certificate - no cert');

$s = Test::Nginx::IMAP->new(
	PeerAddr => '127.0.0.1:18082',
	SSL => 1,
	SSL_cert_file => "$d/other.crt",
	SSL_key_file => "$d/other.key"
);
$s->check(qr/BYE SSL certificate error/,
	'partial_chain trusted_certificate - unknown cert rejected');

$s = Test::Nginx::IMAP->new(PeerAddr => '127.0.0.1:18085', SSL => 1);
$s->ok('partial_chain optional - no cert');
$s->send('1 AUTHENTICATE PLAIN ' . $cred->("p3"));

$s = Test::Nginx::IMAP->new(
	PeerAddr => '127.0.0.1:18085',
	SSL => 1,
	SSL_cert_file => "$d/end.crt",
	SSL_key_file => "$d/end.key"
);
$s->ok('partial_chain optional - leaf cert accepted');
$s->send('1 AUTHENTICATE PLAIN ' . $cred->("p4"));

$s = Test::Nginx::IMAP->new(
	PeerAddr => '127.0.0.1:18085',
	SSL => 1,
	SSL_cert_file => "$d/other.crt",
	SSL_key_file => "$d/other.key"
);
$s->check(qr/BYE SSL certificate error/,
	'partial_chain optional - unknown cert rejected');

$t->stop();

my $f = $t->read_file('auth.log');

like($f, qr!^SUCCESS:(/?CN=end):p1$!m,
	'partial_chain auth log - leaf cert via client_certificate');
like($f, qr!^SUCCESS:(/?CN=end):p2$!m,
	'partial_chain auth log - leaf cert via trusted_certificate');

###############################################################################
