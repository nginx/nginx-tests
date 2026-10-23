#!/usr/bin/perl

# Tests for HTTP/2 fair scheduling across timers and response lifecycle events.

###############################################################################

use warnings;
use strict;

use Test::More;
use IO::Socket::INET;
use Socket qw/ CRLF /;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;
use Test::Nginx::HTTP2;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/http http_v2 proxy/)->plan(23)
	->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        http2 on;
        http2_fair_scheduling on;

        location / {
            add_trailer X-Trailer done;
        }

        location /rate {
            alias %%TESTDIR%%/body;
            limit_rate 16k;
            add_trailer X-Trailer done;
        }

        location /idle {
            proxy_pass http://127.0.0.1:8081;
            proxy_http_version 1.1;
            proxy_buffering off;
            add_trailer X-Trailer done;
        }
    }
}

EOF

my $body = join '', map { sprintf '%08x', $_ } 0 .. 6143;
my $prefix = 'BEFORE-' x 512;
my $suffix = 'AFTER--' x 512;
$t->write_file('body', $body);
$t->write_file('empty', '');
$t->run_daemon(\&http_daemon);
$t->run()->waitforsocket('127.0.0.1:' . port(8081));

###############################################################################

# All stream and connection windows exceed the combined finite bodies.  The
# rate-limited response must resume through its timer, while HEAD, empty bodies,
# and trailers must complete without creating an extra productive turn.
# No assertion depends on the relative completion time of these streams.

my $s = connection();
$s->start_chain();
my $rate = $s->new_stream({ path => '/rate' });
my $normal = $s->new_stream({ path => '/body' });
my $head = $s->new_stream({ path => '/body', method => 'HEAD' });
my $empty = $s->new_stream({ path => '/empty' });
$s->send_chain();
my @ids = ($rate, $normal, $head, $empty);
my $frames = $s->read(all => [map { { sid => $_, fin => 1 } } @ids]);

ok(payload($frames, $rate) eq $body, 'rate timer preserves payload');
ok(payload($frames, $normal) eq $body, 'concurrent payload integrity');
my ($headers) = grep { $_->{sid} == $head && $_->{type} eq 'HEADERS' }
	@$frames;
is($headers->{headers}{':status'}, 200, 'HEAD status');
is($headers->{headers}{'content-length'}, length($body), 'HEAD length');
is(scalar(grep { $_->{sid} == $head && $_->{type} eq 'DATA' } @$frames),
	0, 'HEAD has no DATA frames');
is(scalar(grep { $_->{sid} == $head && $_->{type} eq 'HEADERS'
	&& $_->{flags} & 1 } @$frames), 1, 'HEAD ends with HEADERS');
is(trailer($frames, $rate), 'done', 'rate timer final trailer');
is(trailer($frames, $normal), 'done', 'concurrent final trailer');
is(trailer($frames, $empty), 'done', 'empty response final trailer');
is(payload($frames, $empty), '', 'empty response has no payload');
is(fin_count($frames, \@ids), 4, 'exactly one END_STREAM per response');
is(scalar(grep { $_->{type} =~ /^(?:GOAWAY|RST_STREAM)$/ } @$frames),
	0, 'timer and lifecycle responses have no protocol errors');

# The independent origin sends a prefix and holds the connection open.  Its
# suffix is released through a separate HTTP control request only after the
# other HTTP/2 response and a PING have completed.  This is a protocol barrier,
# not a sleep-based assertion about scheduling speed or idle CPU consumption.

$s = connection();
my $idle = $s->new_stream({ path => '/idle' });
my @idle = @{$s->read(all => [{ sid => $idle, length => length($prefix) }])};
is(payload(\@idle, $idle), $prefix, 'idle origin prefix');
is(fin_count(\@idle, [$idle]), 0, 'idle origin remains open');

my $peer = $s->new_stream({ path => '/body' });
$frames = $s->read(all => [{ sid => $peer, fin => 1 }]);
ok(payload($frames, $peer) eq $body, 'idle origin permits peer payload');
is(fin_count($frames, [$peer]), 1, 'idle origin permits peer completion');
push @idle, grep { $_->{sid} == $idle } @$frames;

$s->h2_ping('IDLEPING');
$frames = $s->read(all => [{ type => 'PING' }]);
my ($ping) = grep { $_->{type} eq 'PING' } @$frames;
is($ping->{value}, 'IDLEPING', 'idle origin permits PING acknowledgement');

my $control = IO::Socket::INET->new(
	Proto => 'tcp',
	PeerAddr => '127.0.0.1:' . port(8081)
) or die "Can't connect origin control socket: $!\n";
$control->autoflush(1);
print $control 'GET /release HTTP/1.1' . CRLF
	. 'Host: localhost' . CRLF . 'Connection: close' . CRLF . CRLF;
my $released = do { local $/; <$control> };
close $control;
like($released, qr/^HTTP\/1\.1 200 /, 'origin release acknowledged');

push @idle, @{$s->read(all => [{ sid => $idle, fin => 1 }])};
is(payload(\@idle, $idle), $prefix . $suffix, 'idle origin resumed integrity');
is(trailer(\@idle, $idle), 'done', 'idle origin final trailer');
is(fin_count(\@idle, [$idle]), 1, 'idle origin finishes once');

my $reuse = $s->new_stream({ path => '/body' });
$frames = $s->read(all => [{ sid => $reuse, fin => 1 }]);
ok(payload($frames, $reuse) eq $body, 'connection reuse payload');
is(fin_count($frames, [$reuse]), 1, 'connection reuse completion');

###############################################################################

sub connection {
	my $s = Test::Nginx::HTTP2->new();
	$s->start_chain();
	$s->h2_settings(0, 0x4 => 2**24);
	$s->h2_window(2**24);
	$s->send_chain();
	$s->read(all => [{ type => 'SETTINGS' }]);
	return $s;
}

sub payload {
	my ($frames, $sid) = @_;
	return join '', map { $_->{data} }
		grep { $_->{sid} == $sid && $_->{type} eq 'DATA' } @$frames;
}

sub trailer {
	my ($frames, $sid) = @_;
	my ($frame) = grep { $_->{sid} == $sid && $_->{type} eq 'HEADERS'
		&& $_->{flags} & 1 && exists $_->{headers}{'x-trailer'} } @$frames;
	return $frame ? $frame->{headers}{'x-trailer'} : undef;
}

sub fin_count {
	my ($frames, $ids) = @_;
	my %fin;
	$fin{$_->{sid}}++ for grep { $_->{flags} & 1
		&& ($_->{type} eq 'DATA' || $_->{type} eq 'HEADERS') } @$frames;
	return scalar grep { ($fin{$_} || 0) == 1 } @$ids;
}

sub http_daemon {
	my $server = IO::Socket::INET->new(
		Proto => 'tcp',
		LocalHost => '127.0.0.1:' . port(8081),
		Listen => 5,
		Reuse => 1
	) or die "Can't create listening socket: $!\n";
	my $idle;
	local $SIG{PIPE} = 'IGNORE';

	while (my $client = $server->accept()) {
		$client->autoflush(1);
		my $headers = '';
		while (<$client>) {
			$headers .= $_;
			last if /^\x0d?\x0a$/;
		}

		if ($headers =~ m!^GET /idle !) {
			print $client 'HTTP/1.1 200 OK' . CRLF
				. 'Transfer-Encoding: chunked' . CRLF
				. 'Connection: close' . CRLF . CRLF
				. sprintf('%x', length($prefix)) . CRLF
				. $prefix . CRLF;
			$idle = $client;
			next;
		}

		if ($headers =~ m!^GET /release !) {
			if ($idle) {
				print $idle sprintf('%x', length($suffix)) . CRLF
					. $suffix . CRLF . '0' . CRLF . CRLF;
				close $idle;
				undef $idle;
			}
			print $client 'HTTP/1.1 200 OK' . CRLF
				. 'Content-Length: 0' . CRLF
				. 'Connection: close' . CRLF . CRLF;
		}
		close $client;
	}
}

###############################################################################
