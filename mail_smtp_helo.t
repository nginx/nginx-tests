#!/usr/bin/perl

# (C) Nginx, Inc.

# Tests for mail smtp module, the greeting sent to the upstream after
# HELO or EHLO from the client, with and without STARTTLS.

###############################################################################

use warnings;
use strict;

use Test::More;

use MIME::Base64;
use Socket qw/ CRLF /;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;
use Test::Nginx::SMTP;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

local $SIG{PIPE} = 'IGNORE';

my $t = Test::Nginx->new()->has(qw/mail mail_ssl smtp http socket_ssl/)
	->has_daemon('openssl')->plan(15)
	->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

mail {
    auth_http  http://127.0.0.1:8080/mail/auth;
    xclient    off;

    ssl_certificate_key localhost.key;
    ssl_certificate localhost.crt;

    server {
        listen     127.0.0.1:8025;
        protocol   smtp;
        smtp_auth  plain;
        starttls   on;
    }
}

http {
    %%TEST_GLOBALS_HTTP%%

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        location = /mail/auth {
            add_header Auth-Status OK;
            add_header Auth-Server 127.0.0.1;
            add_header Auth-Port %%PORT_8026%%;
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

$t->run_daemon(\&smtp_test_daemon);
$t->run()->waitforsocket('127.0.0.1:' . port(8026));

###############################################################################

my $auth = 'AUTH PLAIN ' . encode_base64("\0test\@example.com\0secret", '');

# the upstream is greeted according to the last HELO or EHLO of the client

my $s = Test::Nginx::SMTP->new();
$s->read();
$s->send('HELO example.com');
$s->ok('helo');
$s->send($auth);
$s->authok('auth after helo');
like(greeting(1), qr/^HELO /, 'helo - upstream greeting');

$s = Test::Nginx::SMTP->new();
$s->read();
$s->send('EHLO example.com');
$s->ok('ehlo');
$s->send($auth);
$s->authok('auth after ehlo');
like(greeting(2), qr/^EHLO /, 'ehlo - upstream greeting');

$s = Test::Nginx::SMTP->new();
$s->read();
$s->send('EHLO example.com');
$s->ok('ehlo before helo');
$s->send('HELO example.com');
$s->ok('helo after ehlo');
$s->send($auth);
$s->authok('auth after ehlo and helo');

TODO: {
local $TODO = 'not yet' unless $t->has_version('1.31.10');

like(greeting(3), qr/^HELO /, 'helo after ehlo - upstream greeting');

}

# RFC 3207, 4.2: knowledge obtained before STARTTLS is discarded

$s = Test::Nginx::SMTP->new();
$s->read();
$s->send('EHLO example.com');
$s->ok('ehlo before starttls');
$s->send('STARTTLS');
$s->ok('starttls');

require IO::Socket::SSL;
IO::Socket::SSL->start_SSL($s->socket,
	SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE())
	or die $IO::Socket::SSL::SSL_ERROR . "\n";

$s->send('HELO example.com');
$s->ok('helo after starttls');
$s->send($auth);
$s->authok('auth after starttls');

TODO: {
local $TODO = 'not yet' unless $t->has_version('1.31.10');

like(greeting(4), qr/^HELO /, 'helo after starttls - upstream greeting');

}

###############################################################################

sub greeting {
	my ($n) = @_;

	open my $f, '<', "$d/greetings.log" or return;
	my @lines = <$f>;
	close $f;

	return $lines[$n - 1];
}

sub smtp_test_daemon {
	my $server = IO::Socket::INET->new(
		Proto => 'tcp',
		LocalAddr => '127.0.0.1:' . port(8026),
		Listen => 5,
		Reuse => 1
	)
		or die "Can't create listening socket: $!\n";

	while (my $client = $server->accept()) {
		$client->autoflush(1);
		print $client "220 fake esmtp server ready" . CRLF;

		while (<$client>) {
			Test::Nginx::log_core('||', $_);

			if (/^quit/i) {
				print $client '221 quit ok' . CRLF;

			} elsif (/^(ehlo|helo)/i) {
				open my $f, '>>', "$d/greetings.log" or die "$!";
				print $f $_;
				close $f;
				print $client '250 hello ok' . CRLF;

			} else {
				print $client "500 unknown command" . CRLF;
			}
		}

		close $client;
	}
}

###############################################################################
