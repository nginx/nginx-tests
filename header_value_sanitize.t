#!/usr/bin/perl

# Tests that a response field value carrying CR, LF or NUL cannot inject a
# new field into the HTTP/1.1 response.
#
# The invariant under test is deliberately policy-agnostic: whatever nginx
# does with the offending bytes, the response must not contain a field line
# created by them.  That holds both when the bytes are replaced in place
# and when the request is rejected, so this test does not prejudge the
# open question of which of the two nginx should do.

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

my $t = Test::Nginx->new()->has(qw/http proxy/)->plan(4);

$t->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        proxy_http_version 1.1;
        proxy_pass_trailers on;
        proxy_set_header Connection "te, close";
        proxy_set_header TE "trailers";

        location /hdr/ {
            add_header X-Value $uri always;
            return 200 "ok\n";
        }

        location /body/ {
            proxy_pass http://127.0.0.1:8082/;
            add_header X-Value $request_body always;
        }

        location /redir/ {
            return 302 http://$host$uri;
        }

        location /trailer/ {
            add_trailer X-Value $uri always;
            proxy_pass http://127.0.0.1:8081/;
        }
    }

    server {
        listen       127.0.0.1:8081;
        server_name  localhost;

        location / {
            add_trailer X-Upstream $uri always;
            return 200 "body\n";
        }
    }
}

EOF

$t->run_daemon(\&http_daemon);
$t->run()->waitforsocket('127.0.0.1:' . port(8082));

###############################################################################

my $crlf = '%0d%0aX-Injected:%20yes';
my $r;

# a field value carrying CRLF must not create a field line

$r = http_get("/hdr/$crlf");
unlike($r, qr/^X-Injected:/m, 'add_header does not emit an injected field');

$r = http_get("/redir/$crlf");
unlike($r, qr/^X-Injected:/m, 'Location does not emit an injected field');

$r = http11("/trailer/$crlf");
unlike($r, qr/^X-Injected:/m, 'add_trailer does not emit an injected field');

# a field value carrying NUL must not put a NUL byte on the wire

$r = post_body('/body/', "head\x00tail");
unlike($r, qr/\x00/, 'add_header does not emit a NUL byte');

###############################################################################

sub http11 {
	my ($uri) = @_;
	return http(<<EOF);
GET $uri HTTP/1.1
Host: localhost
Connection: te, close
TE: trailers

EOF
}

sub post_body {
	my ($uri, $body) = @_;
	return http(<<"EOF");
POST $uri HTTP/1.0
Host: localhost
Content-Length: @{[ length $body ]}

$body
EOF
}

###############################################################################

sub http_daemon {
	my $server = IO::Socket::INET->new(
		Proto => 'tcp',
		LocalHost => '127.0.0.1:' . port(8082),
		Listen => 5,
		Reuse => 1
	) or die "Can't create listening socket: $!\n";

	local $SIG{PIPE} = 'IGNORE';

	while (my $client = $server->accept()) {
		$client->autoflush(1);
		my $headers = '';
		while (<$client>) {
			$headers .= $_;
			last if (/^\x0d?\x0a$/);
		}
		print $client
			"HTTP/1.1 200 OK\r\n" .
			"Content-Type: text/plain\r\n" .
			"Content-Length: 3\r\n" .
			"\r\n" .
			"ok\n";
		close $client;
	}
}

###############################################################################
