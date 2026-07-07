#!/usr/bin/perl

# (C) Nginx, Inc.

# Test for upstream keepalive: pooled connection must survive unsolicited
# server-originated data.  Prior to the fix in
# ngx_http_upstream_keepalive_close_handler(), any byte arriving on an
# idle pooled upstream connection (for example, HTTP/2 SETTINGS or PING
# frames on a grpc_pass upstream) caused the close handler to evict the
# entry, because only EAGAIN from recv(MSG_PEEK) avoided the close path.

###############################################################################

use warnings;
use strict;

use Test::More;

use IO::Select;
use IO::Socket::INET;
use Socket qw/ CRLF /;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/http proxy upstream_keepalive/)
	->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    upstream backend {
        server 127.0.0.1:8081;
        keepalive 4;
    }

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        location / {
            proxy_pass http://backend;
            proxy_http_version 1.1;
            proxy_set_header Connection "";
        }
    }
}

EOF

my $accept_file = $t->testdir() . '/accepts';

$t->run_daemon(\&http_daemon, port(8081), $accept_file);
$t->run()->waitforsocket('127.0.0.1:' . port(8081));

$t->plan(3);

###############################################################################

# First request establishes the pooled connection.

like(http_get('/'), qr/X-Conn: 1/, 'first request');

# Give the backend time to write its stray byte on the now-idle pooled
# connection.  Pre-fix, nginx's close handler fires immediately and
# evicts the entry.  Post-fix, the byte just sits in the socket buffer.

select undef, undef, undef, 0.5;

# Second request: pre-fix, nginx must open a NEW connection (accept
# count == 2).  Post-fix, nginx tries to reuse the pooled connection.
# The stray byte will corrupt that reuse attempt and cause a 502, but
# only after nginx has attempted reuse - the crucial signal is the
# accept count on the backend, not the HTTP response.

http_get('/');

# Read backend's accept counter.

my $accepts = 0;
if (open my $fh, '<', $accept_file) {
	$accepts = <$fh>;
	chomp $accepts if defined $accepts;
	close $fh;
}

# With the fix: nginx keeps the pooled connection, so the backend
# accepts exactly one TCP connection.  Without the fix: nginx evicts
# after the stray byte and opens a second connection.

is($accepts, 1, 'backend accepted exactly one connection (pool retained)');

# Sanity: with the pool retained, a third request against the same
# upstream will also either reuse the (now-poisoned) pooled entry or
# open a fresh connection.  Just make sure nginx did not crash.

my $r = http_get('/');
like($r, qr/HTTP\/1\.1 (2|5)\d\d/, 'nginx still responding');

###############################################################################

sub http_daemon {
	my ($port, $accept_file) = @_;

	my $server = IO::Socket::INET->new(
		Proto => 'tcp',
		LocalAddr => "127.0.0.1:$port",
		Listen => 5,
		Reuse => 1,
	)
		or die "Can't create listening socket: $!\n";

	local $SIG{PIPE} = 'IGNORE';

	my $ccount = 0;

	# Persist accept count so the parent test process can read it.
	my $write_count = sub {
		if (open my $fh, '>', $accept_file) {
			print $fh $ccount;
			close $fh;
		}
	};
	$write_count->();

	while (my $client = $server->accept()) {
		$client->autoflush(1);

		# Serve one HTTP/1.1 keepalive response, then emit a
		# stray byte on the (from nginx's point of view) idle
		# pooled connection.  Count only real request-bearing
		# connections, not readiness probes from waitforsocket().

		my $headers = '';
		while (<$client>) {
			$headers .= $_;
			last if /^\x0d?\x0a?$/;
		}

		if ($headers ne '') {
			$ccount++;
			$write_count->();

			my $body = "ok\n";
			print $client
				"HTTP/1.1 200 OK" . CRLF .
				"Content-Length: " . length($body) . CRLF .
				"Connection: keep-alive" . CRLF .
				"X-Conn: $ccount" . CRLF .
				CRLF .
				$body;

			# Small delay so nginx has time to return the
			# connection to the pool and arm the close-handler
			# read event before the stray byte arrives.
			select undef, undef, undef, 0.15;

			# Emit a single byte (content irrelevant, any n > 0
			# from recv(MSG_PEEK) reproduces the bug).
			syswrite($client, "\x00");
		}

		# Keep the connection open long enough for nginx to
		# either evict it (pre-fix) or attempt to reuse it
		# (post-fix).  Do not proactively close - we want nginx's
		# behavior, not ours, to drive the outcome.
		my $sel = IO::Select->new($client);
		$sel->can_read(3);

		close $client;
	}
}

###############################################################################
