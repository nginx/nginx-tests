#!/usr/bin/perl

# Tests for forward proxy support in proxy module.

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

plan(skip_all => 'win32') if $^O eq 'MSWin32';

my $t = Test::Nginx->new()->has(qw/http proxy http_v2/)->plan(19);

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

        location / {
            forward_proxy on;
            resolver     127.0.0.1:%%PORT_8980_UDP%% ipv6=off;
            resolver_timeout 2s;
            proxy_connect_timeout 2s;
            proxy_read_timeout 2s;
            proxy_send_timeout 2s;
        }
    }

    server {
        listen       127.0.0.1:8082;
        server_name  localhost;

        http2 on;

        location / {
            forward_proxy on;
            resolver     127.0.0.1:%%PORT_8980_UDP%% ipv6=off;
            resolver_timeout 2s;
            proxy_connect_timeout 2s;
            proxy_read_timeout 2s;
            proxy_send_timeout 2s;
        }
    }

    server {
        listen       127.0.0.1:8083;
        server_name  localhost;

        location / {
            forward_proxy on;
            proxy_connect_timeout 2s;
            proxy_read_timeout 2s;
            proxy_send_timeout 2s;
        }
    }

    server {
        listen       127.0.0.1:8084;
        server_name  localhost;

        http2 on;

        location / {
            forward_proxy on;
            proxy_connect_timeout 2s;
            proxy_read_timeout 2s;
            proxy_send_timeout 2s;
        }
    }
}

EOF

my $dns_ready = $t->testdir() . '/dns.ready';

$t->run_daemon(\&origin_daemon, port(8081));
$t->run_daemon(\&dns_daemon, $t, port(8980), $dns_ready);
$t->run();
$t->waitforsocket('127.0.0.1:' . port(8081));
$t->waitforfile($dns_ready) or die "Can't start dns daemon";

###############################################################################

my $p = port(8081);

my $r = http(<<"EOF");
GET http://127.0.0.1:$p/path?foo=bar HTTP/1.1
Host: wrong.example
Connection: close

EOF
like($r, qr/^HTTP\/1\.1 200 OK/ms, 'h1 absolute-form GET');
like($r, qr/X-URI: \/path\?foo=bar/i, 'h1 rewrites to origin-form');
like($r, qr/X-Host: 127\.0\.0\.1:$p/i, 'h1 rewrites Host from target');

$r = http(<<"EOF");
HEAD http://127.0.0.1:$p/head HTTP/1.1
Host: ignored.example
Connection: close

EOF
like($r, qr/X-Method: HEAD/i, 'h1 absolute-form HEAD');
unlike($r, qr/body=HEAD/ms, 'h1 HEAD suppresses upstream body');

$r = http(<<"EOF", body => 'post-body');
POST http://127.0.0.1:$p/post HTTP/1.1
Host: ignored.example
Content-Length: 9
Connection: close

EOF
like($r, qr/X-Body: post-body/i, 'h1 POST forwards body');

like(http(<<"EOF"), qr/^HTTP\/1\.1 400 Bad Request/ms,
GET /origin-form HTTP/1.1
Host: localhost
Connection: close

EOF
	'h1 origin-form rejected');

like(http(<<"EOF"), qr/^HTTP\/1\.1 400 Bad Request/ms,
GET https://127.0.0.1:$p/secure HTTP/1.1
Host: localhost
Connection: close

EOF
	'h1 https target requires CONNECT');

like(http(<<"EOF"), qr/^HTTP\/1\.1 405 Not Allowed/ms,
CONNECT 127.0.0.1:$p HTTP/1.1
Host: localhost
Connection: close

EOF
	'h1 CONNECT rejected without tunnel_pass');

$r = http(<<"EOF");
GET http://example.net:$p/resolve HTTP/1.1
Host: ignored.example
Connection: close

EOF
like($r, qr/^HTTP\/1\.1 200 OK/ms, 'h1 hostname target resolved');
like($r, qr/X-Host: example\.net:$p/i,
	'h1 resolved target preserves Host');

$r = http_port(8083, <<"EOF");
GET http://example.net:$p/no-resolver HTTP/1.1
Host: localhost
Connection: close

EOF
like($r, qr/^HTTP\/1\.1 502 Bad Gateway/ms,
	'h1 hostname target without resolver returns 502');

my ($headers, $body) = h2_forward(
	path => '/h2?x=1',
	host => "127.0.0.1:$p",
);
is($headers->{':status'}, '200', 'h2 forward proxy request');
like($body, qr/method=GET\nuri=\/h2\?x=1\nhost=127\.0\.0\.1:$p\nbody=/s,
	'h2 uses :authority and :path as target');

($headers, $body) = h2_forward(
	method => 'POST',
	path => '/h2-post',
	host => "127.0.0.1:$p",
	body => 'h2-body',
);
like($body, qr/body=h2-body$/s, 'h2 POST forwards body');

($headers, $body) = h2_forward(
	scheme => 'https',
	path => '/secure',
	host => "127.0.0.1:$p",
);
is($headers->{':status'}, '400', 'h2 https target rejected without CONNECT');

($headers, $body) = h2_forward(
	path => '/h2-resolve',
	host => "example.net:$p",
);
is($headers->{':status'}, '200', 'h2 hostname target resolved');
like($body, qr/method=GET\nuri=\/h2-resolve\nhost=example\.net:$p\nbody=/s,
	'h2 resolved target preserves Host');

($headers, $body) = h2_forward(
	port => 8084,
	path => '/h2-no-resolver',
	host => "example.net:$p",
);
is($headers->{':status'}, '502',
	'h2 hostname target without resolver returns 502');

###############################################################################

sub h2_forward {
	my (%args) = @_;

	my $s = Test::Nginx::HTTP2->new(port($args{port} || 8082), pure => 1);
	my $sid = $s->new_stream({
		method => $args{method} || 'GET',
		scheme => $args{scheme} || 'http',
		path => $args{path} || '/',
		host => $args{host} || 'localhost',
		defined $args{body} ? (body => $args{body}) : (),
	});

	my $frames = $s->read(all => [{ sid => $sid, fin => 1 }], wait => 2);
	my ($headers) = map { $_->{headers} } grep { $_->{type} eq 'HEADERS' } @$frames;
	my $body = join('', map { $_->{data} } grep { $_->{type} eq 'DATA' } @$frames);

	return ($headers, $body);
}

sub http_port {
	my ($port, $request, %extra) = @_;

	my $socket = IO::Socket::INET->new(
		Proto => 'tcp',
		PeerAddr => '127.0.0.1:' . port($port),
	)
		or die "Can't connect to nginx: $!\n";

	return http($request, socket => $socket, %extra);
}

sub origin_daemon {
	my ($port) = @_;

	my $server = IO::Socket::INET->new(
		Proto => 'tcp',
		LocalAddr => '127.0.0.1',
		LocalPort => $port,
		Listen => 5,
		Reuse => 1,
	)
		or die "Can't create listening socket: $!\n";

	while (my $client = $server->accept()) {
		$client->autoflush(1);

		my ($headers, $rest) = read_headers($client);
		next unless defined $headers;

		my ($request, @lines) = split(/\x0d?\x0a/, $headers);
		my ($method, $uri) = split(/ /, $request, 3);
		my (%headers_in, $body, $line);

		for $line (@lines) {
			next unless length $line;

			my ($name, $value) = split(/:\s*/, $line, 2);
			$headers_in{lc $name} = $value;
		}

		if (($headers_in{'content-length'} || 0) > 0) {
			$body = $rest || '';

			if (length($body) < $headers_in{'content-length'}) {
				read($client, my $chunk,
					$headers_in{'content-length'} - length($body));
				$body .= $chunk;
			}

			$body = substr($body, 0, $headers_in{'content-length'});
		} else {
			$body = '';
		}

		my $payload = join("\n",
			"method=$method",
			"uri=$uri",
			"host=" . ($headers_in{'host'} // ''),
			"body=$body");

		my $response = 'HTTP/1.1 200 OK' . CRLF
			. 'X-Method: ' . $method . CRLF
			. 'X-URI: ' . $uri . CRLF
			. 'X-Host: ' . ($headers_in{'host'} // '') . CRLF
			. 'X-Body: ' . $body . CRLF
			. 'Content-Length: ' . length($payload) . CRLF
			. 'Connection: close' . CRLF
			. CRLF;

		print $client $response;
		print $client $payload unless $method eq 'HEAD';

		close $client;
	}
}

sub read_headers {
	my ($client) = @_;
	my $buf = '';

	eval {
		local $SIG{ALRM} = sub { die "timeout\n" };
		alarm(8);

		while ($buf !~ /\x0d?\x0a\x0d?\x0a/ms) {
			my $chunk = '';
			my $n = $client->sysread($chunk, 4096);
			die "unexpected eof\n" unless $n;
			$buf .= $chunk;
		}

		alarm(0);
	};
	alarm(0);

	die $@ if $@ && $@ ne "unexpected eof\n";
	return undef if $@;

	$buf =~ /(.*?\x0d?\x0a\x0d?\x0a)(.*)/ms
		or die "Can't parse headers\n";

	return ($1, $2);
}

sub dns_daemon {
	my ($t, $port, $ready) = @_;

	my ($data, $recv_data);
	my $socket = IO::Socket::INET->new(
		LocalAddr => '127.0.0.1',
		LocalPort => $port,
		Proto => 'udp',
	)
		or die "Can't create listening socket: $!\n";

	open my $fh, '>', $ready or die "Can't create $ready: $!\n";
	close $fh;

	while (1) {
		$socket->recv($recv_data, 65536);
		$data = dns_reply($recv_data);
		$socket->send($data);
	}
}

sub dns_reply {
	my ($recv_data) = @_;

	my (@name, @rdata);

	use constant NOERROR => 0;
	use constant A => 1;
	use constant IN => 1;

	my ($len, $offset) = (undef, 12);
	while (1) {
		$len = unpack("\@$offset C", $recv_data);
		last if $len == 0;
		$offset++;
		push @name, unpack("\@$offset A$len", $recv_data);
		$offset += $len;
	}

	$offset -= 1;
	my ($id, $type, $class) = unpack("n x$offset n2", $recv_data);

	my $name = join('.', @name);
	if ($name eq 'example.net' && $type == A) {
		push @rdata, dns_rd_addr(1, '127.0.0.1');
	}

	$len = @name;
	return pack("n6 (C/a*)$len x n2", $id, 0x8180 | NOERROR, 1,
		scalar @rdata, 0, 0, @name, $type, $class) . join('', @rdata);
}

sub dns_rd_addr {
	my ($ttl, $addr) = @_;

	my @octets = split(/\./, $addr);

	return pack('n3N nC4', 0xc00c, 1, 1, $ttl, scalar @octets, @octets);
}

###############################################################################
