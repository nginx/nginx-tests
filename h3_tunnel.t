#!/usr/bin/perl

# (C) Eugene Grebenschikov
# (C) Liu Dongmiao
# (C) Nginx, Inc.

# Tests for HTTP/3 protocol with http tunnel module.

###############################################################################

use warnings;
use strict;

use Test::More;

use Socket qw/ CRLF /;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;
use Test::Nginx::HTTP3;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/http http_v3 tunnel rewrite cryptx/)
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

    upstream tunnel_upstream {
        server 127.0.0.1:8083;
    }

    resolver 127.0.0.1:%%PORT_8987_UDP%%;
    resolver_timeout 1s;

    tunnel_read_timeout 1s;
    tunnel_connect_timeout 1s;

    server {
        listen       127.0.0.1:%%PORT_8980_UDP%% quic;
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
        listen       127.0.0.1:%%PORT_8981_UDP%% quic;
        server_name  localhost;

        tunnel_pass tunnel_upstream;
    }

    server {
        listen       127.0.0.1:%%PORT_8982_UDP%% quic;
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

$t->run_daemon(\&dns_daemon, $t)->waitforfile($t->testdir . '/' . port(8987))
	or die "dns daemon failed to start\n";

$t->try_run('no tunnel')->plan(21);

###############################################################################

my $p = port(8083);

like(http3_get('/'), qr/SUCCESS/, 'GET');
like(proxy_get('/', "127.0.0.1:$p", 8980), qr/SEE-THIS/, 'CONNECT IP');
like(proxy_get('/', "example.net:$p", 8980),
	qr/SEE-THIS/, 'CONNECT hostname');
like(proxy_get('/', "example.net:$p/", 8980),
	qr/400/, 'CONNECT authority with path');
like(proxy_get('/', "example.net:$p?", 8980),
	qr/400/, 'CONNECT authority with query');
like(proxy_get('/', "example.net:$p#", 8980),
	qr/400/, 'CONNECT authority with fragment');
like(proxy_get('/', "user:pass\@example.net:$p", 8980),
	qr/400/, 'CONNECT authority with userinfo');
like(proxy_get('/', "http://example.net:$p", 8980),
	qr/400/, 'CONNECT authority with scheme');
like(proxy_get('/', 'example.net', 8980),
	qr/400/, 'CONNECT no colon');
like(proxy_get('/', 'example.net:', 8980),
	qr/400/, 'CONNECT no port');
like(proxy_get('/', ":$p", 8980),
	qr/400/, 'CONNECT no host');
like(proxy_get('/', ':', 8980),
	qr/400/, 'CONNECT no host and port');
like(proxy_get('/', 'example.net:65536', 8980),
	qr/400/, 'CONNECT wrong port');
like(proxy_get('/', 'example.net:0', 8980),
	qr/400/, 'CONNECT zero port');
like(proxy_get('/', 'example.net:$p', 8980),
	qr/400/, 'CONNECT rubbish port');
like(proxy_get('/', undef, 8980),
	qr/400/, 'CONNECT no authority');
like(proxy_get('/', "127.0.0.1:$p", 8980, scheme => 'http'),
	qr/400/, 'CONNECT with scheme');
like(proxy_get('/', "127.0.0.1:$p", 8980, path => '/'),
	qr/400/, 'CONNECT with path');
like(proxy_get('/', '127.0.0.1:' . port(8084), 8980), qr/ERROR/,
	'tunnel error page');
like(proxy_get('/', '127.0.0.3:80', 8981),
	qr/SEE-THIS/, 'tunnel static upstream');
like(proxy_get('/', "example.net:$p", 8982),
	qr/SEE-THIS/, 'tunnel explicit');

###############################################################################

sub proxy_get {
	my ($uri, $host, $proxy_port, %extra) = @_;

	my $s = Test::Nginx::HTTP3->new($proxy_port);
	my $sid = $s->new_stream({ body_more => 1,
		headers => connect_headers($host, %extra) });

	my $req = "GET $uri HTTP/1.0" . CRLF . 'Host: localhost' . CRLF . CRLF;

	$s->h3_body($req, $sid, { body_more => 1 });

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
	my @h = ({ name => ':method', value => 'CONNECT' });

	push @h, { name => ':scheme', value => $extra{scheme} }
		if defined $extra{scheme};
	push @h, { name => ':path', value => $extra{path} }
		if defined $extra{path};
	push @h, { name => ':authority', value => $authority }
		if defined $authority;

	return \@h;
}

sub http3_get {
	my ($uri) = @_;

	my $s = Test::Nginx::HTTP3->new(8980);
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
