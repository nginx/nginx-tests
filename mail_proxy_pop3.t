#!/usr/bin/perl

# (C) Vadim Zhestikov
# (C) Nginx, Inc.

# Tests for mail proxy module, POP3 commands sent to backend.

###############################################################################

use warnings;
use strict;

use Test::More;

use MIME::Base64;
use IO::Socket;
use Socket qw/ CRLF /;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;
use Test::Nginx::POP3;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

local $SIG{PIPE} = 'IGNORE';

my $t = Test::Nginx->new()->has(qw/mail pop3 http/)
	->plan(4)->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

mail {
    proxy_pass_error_message  on;
    proxy_timeout  15s;
    auth_http  http://127.0.0.1:8080/mail/auth;

    server {
        listen     127.0.0.1:8110;
        protocol   pop3;
        pop3_auth  plain;
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
            add_header Auth-Port   %%PORT_8111%%;
            add_header Auth-Wait   1;
            return 204;
        }
    }
}

EOF

$t->run_daemon(\&pop3_daemon);
$t->run();

$t->waitforsocket('127.0.0.1:' . port(8111));

###############################################################################

# the backend receives credentials in USER and PASS command lines; a CR or LF
# in a credential, only possible with SASL, would be relayed as an additional
# command line into the authenticated backend session

my $s = Test::Nginx::POP3->new();
$s->read();

$s->send('AUTH PLAIN ' . encode_base64("\0test\@example.com\0secret", ''));
$s->ok('auth plain');

$s->send('XEXTRA');
$s->check(qr/^\+OK extra:\x0d/, 'no extra commands');

TODO: {
local $TODO = 'not yet';

$s = Test::Nginx::POP3->new();
$s->read();

$s->send('AUTH PLAIN '
	. encode_base64("\0test\@example.com" . CRLF . "DELE 1\0secret", ''));
$s->check(qr/^-ERR/, 'crlf in login');

$s = Test::Nginx::POP3->new();
$s->read();

$s->send('AUTH PLAIN '
	. encode_base64("\0test\@example.com\0secret" . CRLF . "DELE 1", ''));
$s->check(qr/^-ERR/, 'crlf in passwd');

}

###############################################################################

sub pop3_daemon {
	my $server = IO::Socket::INET->new(
		Proto => 'tcp',
		LocalAddr => '127.0.0.1:' . port(8111),
		Listen => 5,
		Reuse => 1
	)
		or die "Can't create listening socket: $!\n";

	while (my $client = $server->accept()) {
		$client->autoflush(1);
		print $client '+OK fake pop3 server ready' . CRLF;

		my $extra = '';

		while (<$client>) {
			Test::Nginx::log_core('||', $_);

			if (/^user /i) {
				print $client '+OK user ok' . CRLF;

			} elsif (/^pass /i) {
				print $client '+OK pass ok' . CRLF;

			} elsif (/^xextra/i) {
				print $client '+OK extra:' . $extra . CRLF;

			} elsif (/^quit/i) {
				print $client '+OK quit ok' . CRLF;

			} else {
				# a command line injected into the session;
				# remember it, but stay silent to keep responses
				# in sync with commands sent by nginx

				my $line = $_;
				$line =~ s/\x0d?\x0a\z//;
				$extra .= $line . ';';
			}
		}

		close $client;
	}
}

###############################################################################
