#!/usr/bin/perl

# (C) Maxim Dounin
# (C) Liu Dongmiao
# (C) Nginx, Inc.

# Tests for HTTP/3 protocol with http proxy websockets support.

###############################################################################

use warnings;
use strict;

use Test::More;

use IO::Poll;
use IO::Socket::INET;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;
use Test::Nginx::HTTP3;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

eval {
	require Protocol::WebSocket::Handshake::Server;
	require Protocol::WebSocket::Frame;
};

plan(skip_all => 'Protocol::WebSocket not installed') if $@;

my $t = Test::Nginx->new()->has(qw/http http_v3 proxy cryptx/)
	->has_daemon('openssl')
	->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    ssl_certificate_key localhost.key;
    ssl_certificate localhost.crt;

    server {
        listen       127.0.0.1:%%PORT_8980_UDP%% quic;
        server_name  localhost;

        http3_extended_connect on;

        location / {
            accept_extended_connect on;

            proxy_pass    http://127.0.0.1:8081;
            proxy_http_version 1.1;
            proxy_read_timeout 2s;
            send_timeout 2s;
        }

        location /no_upgrade {
            accept_extended_connect on;

            proxy_pass    http://127.0.0.1:8083;
            proxy_http_version 1.1;
        }
    }

    server {
        listen       127.0.0.1:%%PORT_8981_UDP%% quic;
        server_name  localhost;

        location / {
            proxy_pass    http://127.0.0.1:8081;
            proxy_http_version 1.1;
        }
    }

    server {
        listen       127.0.0.1:8083;
        server_name  localhost;

        location / {
            return 200 "SEE-THIS";
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

$t->run_daemon(\&websocket_fake_daemon, $t);
$t->try_run('no accept_extended_connect')->plan(38);

$t->waitforsocket('127.0.0.1:' . port(8081))
	or die "Can't start test backend";

###############################################################################

# establish websocket connection

my $s = websocket_connect();
ok($s, "websocket handshake");

SKIP: {
	skip "handshake failed", 22 unless $s;

	# send a frame

	websocket_write($s, 'foo');
	is(websocket_read($s), 'bar', "websocket response");

	# send some big frame; Test::Nginx::HTTP3 neither paces nor
	# retransmits, so large transfers are unreliable, hence the
	# smaller size

	websocket_write($s, 'foo' x 300);
	like(websocket_read($s), qr/^(bar){300}$/, "websocket big response");

	# send multiple frames

	for my $i (1 .. 10) {
		websocket_write($s, ('foo' x 300) . $i);
		websocket_write($s, 'bazz' . $i);
	}

	for my $i (1 .. 10) {
		like(websocket_read($s), qr/^(bar){300}\d+$/, "websocket $i");
		is(websocket_read($s), 'bazz' . $i, "websocket small $i");
	}
}

# establish websocket connection with some pipelined data
# and make sure they are correctly passed upstream

undef $s;
$s = websocket_connect("foo");
ok($s, "handshake pipelined");

SKIP: {
	skip "handshake failed", 2 unless $s;

	is(websocket_read($s), "bar", "response pipelined");

	websocket_write($s, "foo");
	is(websocket_read($s), "bar", "next to pipelined");
}

# make sure the synthesized handshake is passed upstream
# and the upgrade headers are not returned to the client

undef $s;
$s = websocket_connect();
ok($s, "handshake headers");

SKIP: {
	skip "handshake failed", 6 unless $s;

	is($s->{headers}->{'upgrade'}, undef, 'no upgrade header');
	is($s->{headers}->{'sec-websocket-accept'}, undef, 'no accept header');

	my $r = $t->read_file('handshake');

	like($r, qr!^GET / HTTP/1\.1!, 'upstream request line');
	like($r, qr/^Upgrade: websocket/mi, 'upstream upgrade header');
	is(scalar(() = $r =~ /^Sec-WebSocket-Key:/mig), 1,
		'upstream key header');
	like($r, qr/^Sec-WebSocket-Key: \S{24}\r$/mi, 'upstream key value');
}

is(connect_status(method => 'GET'), 400, 'protocol with GET');
is(connect_status(port => 8981), 405, 'accept_extended_connect off');

# an upstream that answers 200 instead of 101 does not establish a tunnel,
# and its response is not returned to the client

my ($status, $body) = connect_response(path => '/no_upgrade');
is($status, 502, 'no upgrade');
unlike($body, qr/SEE-THIS/, 'no upgrade body');

my $c = Test::Nginx::HTTP3->new(8980);
my $frames = $c->read(all => [{ type => 'SETTINGS' }]);

my ($frame) = grep { $_->{type} eq "SETTINGS" } @$frames;
is($frame->{8}, 1, 'settings enable connect protocol');

###############################################################################

sub websocket_connect {
	my ($message) = @_;

	my $s = Test::Nginx::HTTP3->new();
	my $sid = $s->new_stream({ body_more => 1,
		headers => connect_headers() });

	$s->h3_max_data(2**30, $sid);
	$s->h3_max_data(2**30);

	$s->h3_body(Protocol::WebSocket::Frame->new($message)->to_bytes,
		$sid, { body_more => 1 }) if defined $message;

	my $frames = $s->read(all => [{ sid => $sid, type => 'HEADERS' }]);

	my ($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
	return unless $frame && $frame->{headers}->{':status'} eq '200';

	return { s => $s, sid => $sid, headers => $frame->{headers},
		frame => Protocol::WebSocket::Frame->new() };
}

sub websocket_write {
	my ($c, $message) = @_;
	my $buf = Protocol::WebSocket::Frame->new($message)->to_bytes;

	# unlike HTTP/1.1, the data has to fit into QUIC packets

	while (length $buf) {
		$c->{s}->h3_body(substr($buf, 0, 1200, ''), $c->{sid},
			{ body_more => 1 });
	}
}

sub websocket_read {
	my ($c) = @_;

	my $got = $c->{frame}->next();
	return $got if defined $got;

	for (1 .. 100) {
		my $frames = $c->{s}->read(all => [{ sid => $c->{sid},
			type => 'DATA' }]);

		last unless websocket_recv($c, $frames);

		$got = $c->{frame}->next();
		return $got if defined $got;
	}

	return $got;
}

sub websocket_recv {
	my ($c, $frames) = @_;
	my $data = '';

	$data .= $_->{data} for grep { $_->{type} eq "DATA" } @$frames;

	# note that append() clears its argument

	my $len = length $data;
	$c->{frame}->append($data) if $len;

	return $len;
}

sub connect_headers {
	my (%extra) = @_;
	my $method = $extra{method} || 'CONNECT';
	my $protocol = $extra{protocol} || 'websocket';
	my $path = $extra{path} || '/';

	return [
		{ name => ':method', value => $method },
		{ name => ':protocol', value => $protocol },
		{ name => ':scheme', value => 'https' },
		{ name => ':path', value => $path },
		{ name => ':authority', value => 'localhost' },
		{ name => 'sec-websocket-version', value => '13' },
		{ name => 'sec-websocket-key', value => 'ignored' }];
}

sub connect_status {
	my ($status) = connect_response(@_);
	return $status;
}

sub connect_response {
	my (%extra) = @_;

	my $s = Test::Nginx::HTTP3->new($extra{port} || 8980);
	my $sid = $s->new_stream({ headers => connect_headers(%extra) });
	my $frames = $s->read(all => [{ sid => $sid, fin => 1 }]);

	my ($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
	my $body = join '', map { $_->{data} }
		grep { $_->{type} eq "DATA" } @$frames;

	return ($frame->{headers}->{':status'}, $body);
}

###############################################################################

sub websocket_fake_daemon {
	my ($t) = @_;

	my $server = IO::Socket::INET->new(
		Proto => 'tcp',
		LocalAddr => '127.0.0.1:' . port(8081),
		Listen => 5,
		Reuse => 1
	)
		or die "Can't create listening socket: $!\n";

	while (my $client = $server->accept()) {
		websocket_handle_client($client, $t);
	}
}

sub websocket_handle_client {
	my ($client, $t) = @_;

	$client->autoflush(1);
	$client->blocking(0);

	my $poll = IO::Poll->new;

	my $hs = Protocol::WebSocket::Handshake::Server->new;
	my $frame = Protocol::WebSocket::Frame->new;
	my $buffer = '';
	my $handshake = '';
	my $closed;
	my $n;

	log2c("(new connection $client)");

	while (1) {
		$poll->mask($client => ($buffer ? POLLIN|POLLOUT : POLLIN));
		my $p = $poll->poll(0.5);
		log2c("(poll $p)");

		foreach ($poll->handles(POLLIN)) {
			$n = $client->sysread(my $chunk, 65536);
			return unless $n;

			log2i($chunk);

			if (!$hs->is_done) {
				$handshake .= $chunk;

				unless (defined $hs->parse($chunk)) {
					log2c("(error: " . $hs->error . ")");
					return;
				}

				if ($hs->is_done) {
					$t->write_file('handshake', $handshake);
					$buffer = $hs->to_string;
					log2o($buffer);
				}

				log2c("(parse: $chunk)");
			}

			$frame->append($chunk);

			while (defined(my $message = $frame->next)) {
				my $f;

				if ($frame->is_close) {
					log2c("(close frame)");
					$closed = 1;
					$f = $frame->new(type => 'close')
						->to_bytes;
				} else {
					$message =~ s/foo/bar/g;
					$f = $frame->new($message)->to_bytes;
				}

				log2o($f);
				$buffer .= $f;
			}
		}

		foreach my $writer ($poll->handles(POLLOUT)) {
			next unless length $buffer;
			$n = $writer->syswrite($buffer);
			substr $buffer, 0, $n, '';
		}

		if ($closed && length $buffer == 0) {
			log2c("(closed)");
			return;
		}
	}
}

sub log2i { Test::Nginx::log_core('|| <<', @_); }
sub log2o { Test::Nginx::log_core('|| >>', @_); }
sub log2c { Test::Nginx::log_core('||', @_); }

###############################################################################
