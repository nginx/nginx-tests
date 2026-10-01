#!/usr/bin/perl

# (C) Eugene Grebenschikov
# (C) Liu Dongmiao
# (C) Nginx, Inc.

# Tests for HTTP/2 protocol with http tunnel module.

###############################################################################

use warnings;
use strict;

use Test::More;

use Socket qw/ CRLF /;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;
use Test::Nginx::HTTP2;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/http http_v2 tunnel rewrite/)
	->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    http2 on;

    upstream tunnel_upstream {
        server 127.0.0.1:8083;
    }

    resolver 127.0.0.1:%%PORT_8987_UDP%%;
    resolver_timeout 1s;

    tunnel_read_timeout 1s;
    tunnel_connect_timeout 1s;

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        location / {
            if ($request_method = CONNECT) {
                tunnel_pass;
                error_page 502 504 /50x.html;
                break;
            }
        }
    }

    server {
        listen       127.0.0.1:8081;
        server_name  localhost;

        tunnel_pass tunnel_upstream;
    }

    server {
        listen       127.0.0.1:8082;
        server_name  localhost;

        tunnel_pass $host:$request_port;
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

$t->write_file('index.html', 'SUCCESS');
$t->write_file('50x.html', 'ERROR');

$t->run_daemon(\&dns_daemon, $t)->waitforfile($t->testdir . '/' . port(8987))
	or die "dns daemon failed to start\n";

$t->try_run('no tunnel')->plan(21);

###############################################################################

my $p = port(8083);

like(http2_get('/'), qr/SUCCESS/, 'GET');
like(proxy_get('/', "127.0.0.1:$p", port(8080)), qr/SEE-THIS/, 'CONNECT IP');
like(proxy_get('/', "example.net:$p", port(8080)),
	qr/SEE-THIS/, 'CONNECT hostname');
like(proxy_get('/', "example.net:$p/", port(8080)),
	qr/400/, 'CONNECT authority with path');
like(proxy_get('/', "example.net:$p?", port(8080)),
	qr/400/, 'CONNECT authority with query');
like(proxy_get('/', "example.net:$p#", port(8080)),
	qr/400/, 'CONNECT authority with fragment');
like(proxy_get('/', "user:pass\@example.net:$p", port(8080)),
	qr/400/, 'CONNECT authority with userinfo');
like(proxy_get('/', "http://example.net:$p", port(8080)),
	qr/400/, 'CONNECT authority with scheme');
like(proxy_get('/', 'example.net', port(8080)),
	qr/400/, 'CONNECT no colon');
like(proxy_get('/', 'example.net:', port(8080)),
	qr/400/, 'CONNECT no port');
like(proxy_get('/', ":$p", port(8080)),
	qr/400/, 'CONNECT no host');
like(proxy_get('/', ':', port(8080)),
	qr/400/, 'CONNECT no host and port');
like(proxy_get('/', 'example.net:65536', port(8080)),
	qr/400/, 'CONNECT wrong port');
like(proxy_get('/', 'example.net:0', port(8080)),
	qr/400/, 'CONNECT zero port');
like(proxy_get('/', 'example.net:$p', port(8080)),
	qr/400/, 'CONNECT rubbish port');
like(proxy_get('/', undef, port(8080)),
	qr/400/, 'CONNECT no authority');
like(proxy_get('/', "127.0.0.1:$p", port(8080), scheme => 'http'),
	qr/400/, 'CONNECT with scheme');
like(proxy_get('/', "127.0.0.1:$p", port(8080), path => '/'),
	qr/400/, 'CONNECT with path');
like(proxy_get('/', '127.0.0.1:' . port(8084), port(8080)), qr/ERROR/,
	'tunnel error page');
like(proxy_get('/', '127.0.0.3:80', port(8081)),
	qr/SEE-THIS/, 'tunnel static upstream');
like(proxy_get('/', "example.net:$p", port(8082)),
	qr/SEE-THIS/, 'tunnel explicit');

###############################################################################

sub proxy_get {
	my ($uri, $host, $proxy_port, %extra) = @_;

	my $s = Test::Nginx::HTTP2->new($proxy_port);
	my $sid = $s->new_stream({ body_more => 1,
		headers => connect_headers($host, %extra) });

	my $req = "GET $uri HTTP/1.0" . CRLF . 'Host: localhost' . CRLF . CRLF;

	$s->h2_body($req, { body_more => 1 });

	my $frames = $s->read(all => [{ sid => $sid, type => 'HEADERS' },
		{ sid => $sid, type => 'DATA' }]);

	my ($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
	my $status = $frame->{headers}->{':status'};

	my $body = $status eq '200' ? '' : $status;
	$body .= $_->{data} for grep { $_->{type} eq "DATA" } @$frames;

	return $body;
}

sub connect_headers {
	my ($authority, %extra) = @_;
	my @h = ({ name => ':method', value => 'CONNECT', mode => 1 });

	push @h, { name => ':scheme', value => $extra{scheme}, mode => 1 }
		if defined $extra{scheme};
	push @h, { name => ':path', value => $extra{path}, mode => 1 }
		if defined $extra{path};
	push @h, { name => ':authority', value => $authority, mode => 1 }
		if defined $authority;

	return \@h;
}

sub http2_get {
	my ($uri) = @_;

	my $s = Test::Nginx::HTTP2->new(port(8080));
	my $sid = $s->new_stream({ path => $uri });
	my $frames = $s->read(all => [{ sid => $sid, fin => 1 }]);

	my $body = '';
	$body .= $_->{data} for grep { $_->{type} eq "DATA" } @$frames;

	return $body;
}

###############################################################################

sub reply_handler {
	my ($recv_data, $port, %extra) = @_;

	my (@name, @rdata);

	use constant NOERROR	=> 0;
	use constant A		=> 1;
	use constant IN		=> 1;

	# default values

	my ($hdr, $rcode, $ttl) = (0x8180, NOERROR, 3600);

	# decode name

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
	if ($name eq 'example.net') {
		if ($type == A) {
			push @rdata, rd_addr($ttl, '127.0.0.1');
		}
	}

	$len = @name;
	pack("n6 (C/a*)$len x n2", $id, $hdr | $rcode, 1, scalar @rdata,
		0, 0, @name, $type, $class) . join('', @rdata);
}

sub rd_addr {
	my ($ttl, $addr) = @_;

	my $code = 'split(/\./, $addr)';

	return pack 'n3N', 0xc00c, A, IN, $ttl if $addr eq '';

	pack 'n3N nC4', 0xc00c, A, IN, $ttl, eval "scalar $code", eval($code);
}

sub dns_daemon {
	my ($t) = @_;

	my ($data, $recv_data);
	my $socket = IO::Socket::INET->new(
		LocalAddr => '127.0.0.1',
		LocalPort => port(8987),
		Proto => 'udp',
	)
		or die "Can't create listening socket: $!\n";

	# signal we are ready

	open my $fh, '>', $t->testdir() . '/' . port(8987);
	close $fh;

	while (1) {
		$socket->recv($recv_data, 65536);
		$data = reply_handler($recv_data);
		$socket->send($data);
	}
}

###############################################################################
