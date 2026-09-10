#!/usr/bin/perl

# Tests for HTTP/2 upstream keepalive with empty responses and control frames.

###############################################################################

use warnings;
use strict;

use Test::More;
use IO::Socket::INET;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;
use Test::Nginx::HTTP2;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/http http_v2 proxy upstream_keepalive/)
	->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    upstream backend {
        server 127.0.0.1:8081;
        keepalive 1;
        keepalive_requests 2;
    }

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        proxy_http_version 2;

        location / {
            proxy_pass http://backend;
        }

        location /unbuffered/ {
            proxy_pass http://backend;
            proxy_buffering off;
        }
    }
}

EOF

$t->run_daemon(\&http_daemon);
$t->waitforsocket('127.0.0.1:' . port(8081));
$t->try_run('no proxy_http_version 2')->plan(40);

###############################################################################

# Each pair starts on a fresh upstream connection.  SETTINGS and PING are sent
# together with the response, so their acknowledgements are still queued when
# the END_STREAM header is parsed.

for my $mode ('buffered', 'unbuffered') {
	for my $response ('200', '204', '304', 'HEAD') {
		my $status = $response eq 'HEAD' ? 200 : $response;
		my $uri = "/$mode/$response";
		my $r = $response eq 'HEAD' ? http_head($uri) : http_get($uri);
		like($r, qr/ $status .*X-Connection: \d+/si,
			"$mode $response response");
		my ($connection) = $r =~ /X-Connection: (\d+)/i;
		$connection = -1 unless defined $connection;

		$r = $response eq 'HEAD' ? http_head($uri) : http_get($uri);
		like($r, qr/X-Connection: $connection\r?\n/i,
			"$mode $response keepalive");
		like($r, qr/X-Settings-Acks: 1\r?\n/i,
			"$mode $response settings ack before reuse");
		like($r, qr/X-Ping-Acks: 1\r?\n/i,
			"$mode $response ping ack before reuse");
	}
}

# Neither GOAWAY nor an incomplete frame after the response permits reuse.

for my $mode ('buffered', 'unbuffered') {
	for my $response ('goaway', 'partial') {
		my $uri = "/$mode/$response";
		my $r = http_get($uri);
		like($r, qr/ 200 .*X-Connection: \d+/si,
			"$mode $response response");
		my ($connection) = $r =~ /X-Connection: (\d+)/i;
		$connection = -1 unless defined $connection;

		like(http_get($uri),
			qr/ 200 .*X-Connection: (?!$connection\r?\n)\d+/si,
			"$mode $response not reused");
	}
}

###############################################################################

sub http_daemon {
	my $server = IO::Socket::INET->new(
		Proto => 'tcp',
		LocalAddr => '127.0.0.1:' . port(8081),
		Listen => 5,
		Reuse => 1
	) or die "Can't create listening socket: $!";

	my $connection = 0;

	while (my $client = $server->accept()) {
		$client->autoflush(1);
		$client->sysread(my $preface, 24) or next;
		$connection++;

		my $c = Test::Nginx::HTTP2->new(1, socket => $client,
			pure => 1, preface => '');
		my ($settings, $pings, $requests) = (0, 0, 0);

		while (1) {
			my $frames = $c->read(all => [{ type => 'HEADERS' }]);
			$settings += grep {
				$_->{type} eq 'SETTINGS' && $_->{flags} == 1
			} @$frames;
			$pings += grep {
				$_->{type} eq 'PING' && $_->{flags} == 1
			} @$frames;

			my ($frame) = grep { $_->{type} eq 'HEADERS' } @$frames;
			last unless $frame;
			my ($response) = $frame->{headers}{':path'} =~ m|([^/]+)$|;
			my $status = $response =~ /^\d+$/ ? $response : 200;
			my $length = $response eq 'HEAD' || $status == 304 ? 100 : 0;
			my @headers = (
				{ name => ':status', value => $status },
				{ name => 'x-connection', value => $connection, mode => 4 },
				{ name => 'x-settings-acks', value => $settings, mode => 4 },
				{ name => 'x-ping-acks', value => $pings, mode => 4 }
			);
			push @headers, { name => 'content-length', value => $length }
				unless $status == 204;

			$c->start_chain();
			$c->h2_settings(0);
			$c->h2_settings(1) unless $requests++;
			$c->h2_ping('12345678');
			$c->h2_goaway(0, $frame->{sid}, 0) if $response eq 'goaway';
			$c->new_stream({ headers => \@headers }, $frame->{sid});
			$c->raw_write(pack('x2C2', 8, 6)) if $response eq 'partial';
			$c->send_chain();
		}
	}
}

###############################################################################
