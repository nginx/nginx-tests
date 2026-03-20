#!/usr/bin/perl

# (C) MozerBYU

# Tests for http ssl module, $ssl_handshake_rtt variable.

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
	->has(qw/http http_ssl rewrite/)
	->has_daemon('openssl');

$t->write_file_expand('nginx.conf', <<'EOF_CONF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    log_format rtt '$ssl_protocol:$ssl_handshake_rtt';

    server {
        listen       127.0.0.1:8443 ssl;
        server_name  localhost;

        ssl_certificate_key localhost.key;
        ssl_certificate localhost.crt;
        ssl_protocols TLSv1.2 TLSv1.3;

        access_log %%TESTDIR%%/rtt.log rtt;

        location / {
            return 200 "ok";
        }
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

$t->run()->plan(11);

###############################################################################

# use openssl s_client to force specific TLS protocol versions

my ($out, $err, $rc);

($out, $err, $rc) = openssl_get('-tls1');
unlike($out, qr/200 OK/ms, 'TLSv1.0 rejected');

($out, $err, $rc) = openssl_get('-tls1_1');
unlike($out, qr/200 OK/ms, 'TLSv1.1 rejected');

($out, $err, $rc) = openssl_get('-tls1_2');
like($out, qr/200 OK/ms, 'TLSv1.2 request');

# OpenSSL 3.2+ exposes handshake RTT when it can be calculated

my ($tls13_out, $tls13_err, $tls13_rc);

if ($t->has_module('OpenSSL') && $t->has_feature('openssl:3.2')) {
	($tls13_out, $tls13_err, $tls13_rc) = openssl_get('-tls1_3');
}

$t->stop();

my @log = grep { length } split /\n/, eval { $t->read_file('rtt.log') };
my @rejected = grep { $_ eq '-:-' } @log;
my ($tls12) = grep { /^TLSv1\.2:/ } @log;

is(scalar(@log), defined $tls13_out ? 4 : 3, 'access log lines');
is(scalar(@rejected), 2, 'pre-TLSv1.2 rejected logged');
ok(defined $tls12, 'TLSv1.2 logged');
like($tls12, qr/^TLSv1\.2:(?:\d+)?$/, 'TLSv1.2 handshake rtt');

SKIP: {
	skip 'OpenSSL 3.2+ build', 1
		if $t->has_module('OpenSSL') && $t->has_feature('openssl:3.2');
	skip 'non-OpenSSL build', 1
		unless $t->has_module('OpenSSL');

	is($tls12, 'TLSv1.2:', 'pre-3.2 handshake rtt empty');
}

SKIP: {
	skip 'OpenSSL before 3.2', 3
		unless $t->has_module('OpenSSL') && $t->has_feature('openssl:3.2');

	my ($tls13) = grep { /^TLSv1\.3:/ } @log;

	like($tls13_out, qr/200 OK/ms, 'TLSv1.3 request');
	ok(defined $tls13, 'TLSv1.3 logged');
	like($tls13, qr/^TLSv1\.3:\d+$/, 'TLSv1.3 handshake rtt');
}

###############################################################################

sub openssl_get {
	my ($flag) = @_;
	my ($in, $out, $err);

	$err = gensym();

	my $pid = open3($in, $out, $err, 'openssl', 's_client',
		'-connect', '127.0.0.1:' . port(8443),
		'-servername', 'localhost',
		'-quiet', $flag);

	print $in "GET / HTTP/1.0\r\nHost: localhost\r\n\r\n";
	close $in;

	local $/;
	my $stdout = <$out>;
	my $stderr = <$err>;

	waitpid($pid, 0);

	return ($stdout || '', $stderr || '', $? >> 8);
}

###############################################################################
