#!/usr/bin/perl

# (C) Vadim Zhestikov
# (C) Nginx, Inc.

# Tests for http ssl module, $ssl_sigalgs variable.

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

$t->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    server {
        listen       127.0.0.1:8443 ssl;
        server_name  localhost;

        ssl_certificate     localhost.crt;
        ssl_certificate_key localhost.key;

        location / {
            return 200 $ssl_sigalgs;
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

system("openssl req -x509 -new "
	. "-subj '/CN=localhost/' "
	. "-keyout $d/localhost.key -out $d/localhost.crt "
	. "-nodes -days 3650 -newkey rsa:2048 "
	. "-config $d/openssl.conf >>$d/openssl.out 2>&1") == 0
	or die "Can't create certificate\n";

$t->try_run('no ssl_sigalgs')->plan(4);

###############################################################################

my $r;

# $ssl_sigalgs lists all sigalgs from ClientHello, colon-separated;
# on OpenSSL 4.0+ entries are TLS scheme names (e.g. "rsa_pkcs1_sha256"),
# on older OpenSSL entries are raw TLS SignatureScheme codes (e.g. "0x0401")

$r = get();
like($r, qr/\w/, 'ssl_sigalgs non-empty');

# format: colon-separated TLS scheme names or 0xHHHH hex codes

like($r, qr/^(?:[\w-]+|0x[0-9a-f]{4})(?::(?:[\w-]+|0x[0-9a-f]{4}))*$/,
	'ssl_sigalgs format');

# rsa_pkcs1_sha256 is always advertised; name on OpenSSL 4.0+, hex on older

like($r, qr/rsa_pkcs1_sha256|RSA-SHA256|0x0401/,
	'ssl_sigalgs rsa_pkcs1_sha256 present');

# rsa_pss_rsae_sha256: TLS scheme name on OpenSSL 4.0+, hex code on older;
# use SSL_CTRL_SET_SIGALGS_LIST (98) to restrict the client sigalg list

SKIP: {
	my $ssleay = Net::SSLeay::SSLeay();
	skip 'Net::SSLeay too old', 1
		if $ssleay < 0x1000200f || $ssleay == 0x20000000;

	$r = get(sub {
		Net::SSLeay::CTX_ctrl($_[0], 98, 0, 'rsa_pss_rsae_sha256')
			or die "SSL_CTRL_SET_SIGALGS_LIST failed";
	});
	like($r, qr/^(?:rsa_pss_rsae_sha256|0x0804)$/,
		'ssl_sigalgs rsa_pss_rsae_sha256');
}

###############################################################################

sub get {
	my ($ctx_cb) = @_;

	my $r = http_get('/',
		SSL => 1,
		SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(),
		$ctx_cb ? (SSL_create_ctx_callback => $ctx_cb) : (),
	);

	$r =~ s/.*?\r\n\r\n//s;
	chomp $r;
	return $r;
}

###############################################################################
