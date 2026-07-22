#!/usr/bin/perl

# (C) MozerBYU

# Tests for stream ssl module, $ssl_handshake_rtt variable.

###############################################################################

use warnings;
use strict;

use Test::More;

use IPC::Open3;
use Symbol qw/ gensym /;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

plan(skip_all => 'win32') if $^O eq 'MSWin32';

my $t = Test::Nginx->new()
	->has(qw/stream stream_ssl stream_return/)
	->has_daemon('openssl');

$t->write_file_expand('nginx.conf', <<'EOF_CONF');

%%TEST_GLOBALS%%

daemon off;

events {
}

stream {
    %%TEST_GLOBALS_STREAM%%

    server {
        listen       127.0.0.1:8443 ssl;
        ssl_certificate_key localhost.key;
        ssl_certificate localhost.crt;
        ssl_protocols TLSv1.2 TLSv1.3;

        return "$ssl_protocol:$ssl_handshake_rtt";
    }
}

EOF_CONF

$t->write_file('openssl.conf', <<'EOF_CERT');
[ req ]
default_bits = 2048
encrypt_key = no
distinguished_name = req_distinguished_name
[ req_distinguished_name ]
EOF_CERT

my $d = $t->testdir();

system('openssl req -x509 -new '
	. "-config $d/openssl.conf -subj /CN=localhost/ "
	. "-out $d/localhost.crt -keyout $d/localhost.key "
	. ">>$d/openssl.out 2>&1") == 0
	or die "Can't create certificate for localhost: $!\n";

$t->run()->plan(7);

###############################################################################

my ($out, $err, $rc);

($out, $err, $rc) = openssl_get('-tls1');
unlike($out, qr/^TLSv1\.0:/ms, 'TLSv1.0 rejected');

($out, $err, $rc) = openssl_get('-tls1_1');
unlike($out, qr/^TLSv1\.1:/ms, 'TLSv1.1 rejected');

($out, $err, $rc) = openssl_get('-tls1_2');
like($out, qr/^TLSv1\.2:(?:\d+)?$/ms, 'TLSv1.2 handshake rtt');

SKIP: {
	skip 'OpenSSL 3.2+ build', 1
		if $t->has_module('OpenSSL') && $t->has_feature('openssl:3.2');
	skip 'non-OpenSSL build', 1
		unless $t->has_module('OpenSSL');

	is($out, 'TLSv1.2:', 'pre-3.2 handshake rtt empty');
}

SKIP: {
	skip 'OpenSSL before 3.2', 3
		unless $t->has_module('OpenSSL') && $t->has_feature('openssl:3.2');

	my ($tls13_out, $tls13_err, $tls13_rc) = openssl_get('-tls1_3');

	like($tls13_out, qr/^TLSv1\.3:\d+$/ms, 'TLSv1.3 handshake rtt');
	unlike($tls13_out, qr/^TLSv1\.3:$/ms, 'TLSv1.3 handshake rtt not empty');
	is($tls13_rc, 0, 'TLSv1.3 request');
}

$t->stop();

###############################################################################

sub openssl_get {
	my ($flag) = @_;
	my ($in, $out, $err);

	$err = gensym();

	my $pid = open3($in, $out, $err, 'openssl', 's_client',
		'-connect', '127.0.0.1:' . port(8443),
		'-servername', 'localhost',
		'-quiet', $flag);

	close $in;

	local $/;
	my $stdout = <$out>;
	my $stderr = <$err>;

	waitpid($pid, 0);

	$stdout =~ s/[\r\n]+\z// if defined $stdout;

	return ($stdout || '', $stderr || '', $? >> 8);
}

###############################################################################
