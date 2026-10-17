#!/usr/bin/perl

# (C) Nginx, Inc.

# Tests for nginx mail proxy module, the "Auth-SMTP" auth_http header.

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

my $t = Test::Nginx->new()->has(qw/mail smtp http map/);

plan(skip_all => 'not yet') unless $t->has_version('1.31.7');

$t->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

mail {
    proxy_pass_error_message  on;
    proxy_timeout             15s;
    auth_http  http://127.0.0.1:8080/mail/auth;
    smtp_auth  plain;
    xclient    off;

    server {
        listen     127.0.0.1:8025;
        protocol   smtp;
        proxy_smtp_auth on;
    }

    server {
        listen     127.0.0.1:8027;
        protocol   smtp;
        proxy_smtp_auth off;
    }
}

http {
    %%TEST_GLOBALS_HTTP%%

    map $http_auth_user $auth_smtp {
        yes@example.com    yes;
        no@example.com     no;
        other@example.com  maybe;
    }

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        location = /mail/auth {
            add_header Auth-Status OK;
            add_header Auth-Server 127.0.0.1;
            add_header Auth-Port   %%PORT_8026%%;
            add_header Auth-SMTP   $auth_smtp;
            return 204;
        }
    }
}

EOF

$t->run_daemon(\&smtp_test_daemon);
$t->run()->plan(8);

$t->waitforsocket('127.0.0.1:' . port(8026));

###############################################################################

# the backend rejects AUTH, a 235 reply means nginx did not send it

# proxy_smtp_auth on

auth(8025, 'test', qr/^535 /, 'on, no header');
auth(8025, 'yes', qr/^535 /, 'on, header yes');
auth(8025, 'no', qr/^235 /, 'on, header no');
auth(8025, 'other', qr/^535 /, 'on, header other');

# proxy_smtp_auth off

auth(8027, 'test', qr/^235 /, 'off, no header');
auth(8027, 'yes', qr/^535 /, 'off, header yes');
auth(8027, 'no', qr/^235 /, 'off, header no');
auth(8027, 'other', qr/^235 /, 'off, header other');

###############################################################################

sub auth {
	my ($port, $user, $re, $name) = @_;

	my $s = Test::Nginx::SMTP->new(PeerAddr => '127.0.0.1:' . port($port));
	$s->read();
	$s->send('EHLO example.com');
	$s->read();
	$s->send('AUTH PLAIN '
		. encode_base64("\0$user\@example.com\0secret", ''));
	$s->check($re, $name);
}

###############################################################################

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
				print $client '250 hello ok' . CRLF;
			} elsif (/^auth plain/i) {
				print $client '535 auth rejected' . CRLF;
			} else {
				print $client "500 unknown command" . CRLF;
			}
		}

		close $client;
	}
}

###############################################################################
