#!/usr/bin/perl

# Tests for http tunnel forward proxy support.

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

plan(skip_all => 'win32') if $^O eq 'MSWin32';

my $has_unix = eval { require IO::Socket::UNIX; 1 };

my $bind1 = IO::Socket::INET->new(LocalAddr => '127.0.0.2');
my $bind2 = IO::Socket::INET->new(LocalAddr => '127.0.0.3');
my $has_bind_retry = defined $bind1 && defined $bind2;

close $bind1 if $bind1;
close $bind2 if $bind2;

my $t = Test::Nginx->new()->has(qw/http tunnel/);

$t->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    map $http_x_tunnel_allow $allow_request {
        allow              1;
        default            0;
    }

    map $upstream_addr $allow_bind {
        ~:%%PORT_8083%%$   0;
        default            1;
    }

    map $upstream_addr $bind_source {
        ~:%%PORT_8083%%$   127.0.0.3;
        default            127.0.0.2;
    }

    upstream error_retry {
        server unix:%%TESTDIR%%/missing.sock;
        server 127.0.0.1:%%PORT_8082%%;
    }

    upstream error_off {
        server unix:%%TESTDIR%%/missing.sock;
        server 127.0.0.1:%%PORT_8082%%;
    }

    upstream bind_retry {
        server 127.0.0.1:%%PORT_8083%%;
        server 127.0.0.1:%%PORT_8084%%;
    }

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        tunnel_pass  127.0.0.1:%%PORT_8081%%;
        tunnel_buffer_size 8k;
        tunnel_connect_timeout 2s;
        tunnel_read_timeout 2s;
        tunnel_send_timeout 2s;
        tunnel_send_lowat 0;
        tunnel_socket_keepalive on;
    }

    server {
        listen       127.0.0.1:8086;
        server_name  localhost;

        tunnel_pass;
        tunnel_buffer_size 8k;
        tunnel_connect_timeout 2s;
        tunnel_read_timeout 2s;
        tunnel_send_timeout 2s;
    }

    server {
        listen       127.0.0.1:8087;
        server_name  localhost;

        tunnel_pass  127.0.0.1:%%PORT_8082%%;
        tunnel_allow_upstream $allow_request;
        tunnel_next_upstream denied;
        tunnel_next_upstream_tries 2;
        tunnel_next_upstream_timeout 5s;
        tunnel_connect_timeout 2s;
        tunnel_read_timeout 2s;
        tunnel_send_timeout 2s;
    }

    server {
        listen       127.0.0.1:8088;
        server_name  localhost;

        tunnel_pass  127.0.0.1:%%PORT_8082%%;
        tunnel_allow_upstream $allow_request;
        tunnel_next_upstream off;
        tunnel_connect_timeout 2s;
        tunnel_read_timeout 2s;
        tunnel_send_timeout 2s;
    }

    server {
        listen       127.0.0.1:8090;
        server_name  localhost;

        tunnel_pass  error_retry;
        tunnel_next_upstream error;
        tunnel_next_upstream_tries 2;
        tunnel_next_upstream_timeout 5s;
        tunnel_connect_timeout 2s;
        tunnel_read_timeout 2s;
        tunnel_send_timeout 2s;
    }

    server {
        listen       127.0.0.1:8091;
        server_name  localhost;

        tunnel_pass  error_off;
        tunnel_next_upstream off;
        tunnel_connect_timeout 2s;
        tunnel_read_timeout 2s;
        tunnel_send_timeout 2s;
    }

    server {
        listen       127.0.0.1:8092;
        server_name  localhost;

        tunnel_pass  bind_retry;
        tunnel_allow_upstream $allow_bind;
        tunnel_next_upstream denied;
        tunnel_next_upstream_tries 2;
        tunnel_next_upstream_timeout 5s;
        tunnel_bind  $bind_source;
        tunnel_bind_dynamic on;
        tunnel_connect_timeout 2s;
        tunnel_read_timeout 2s;
        tunnel_send_timeout 2s;
    }

    server {
        listen       127.0.0.1:8093;
        server_name  localhost;

        tunnel_pass  bind_retry;
        tunnel_allow_upstream $allow_bind;
        tunnel_next_upstream denied;
        tunnel_next_upstream_tries 2;
        tunnel_next_upstream_timeout 5s;
        tunnel_bind  $bind_source;
        tunnel_connect_timeout 2s;
        tunnel_read_timeout 2s;
        tunnel_send_timeout 2s;
    }

    server {
        listen       127.0.0.1:8094;
        server_name  localhost;

        tunnel_pass  unix:%%TESTDIR%%/unix.sock;
        tunnel_connect_timeout 2s;
        tunnel_read_timeout 2s;
        tunnel_send_timeout 2s;
    }

    server {
        listen       127.0.0.1:8095;
        server_name  localhost;

        resolver     127.0.0.1:%%PORT_8980_UDP%% ipv6=off;
        resolver_timeout 2s;
        tunnel_pass  $http_x_tunnel_target;
        tunnel_connect_timeout 2s;
        tunnel_read_timeout 2s;
        tunnel_send_timeout 2s;
    }

    server {
        listen       127.0.0.1:8096;
        server_name  localhost;

        tunnel_pass  $http_x_tunnel_target;
        tunnel_connect_timeout 2s;
        tunnel_read_timeout 2s;
        tunnel_send_timeout 2s;
    }
}

EOF

my $unix_path = $t->testdir() . '/unix.sock';
my $dns_ready = $t->testdir() . '/dns.ready';

for my $backend (
	[ 8081, 'literal' ],
	[ 8082, 'second' ],
	[ 8083, 'bind-one' ],
	[ 8084, 'bind-two' ],
	[ 8085, 'resolved' ],
) {
	$t->run_daemon(\&tunnel_daemon, port($backend->[0]), $backend->[1]);
}

$t->run_daemon(\&tunnel_unix_daemon, $unix_path, 'unix') if $has_unix;
$t->run_daemon(\&dns_daemon, $t, port(8980), $dns_ready);

$t->run();
$t->waitforsocket('127.0.0.1:' . port($_)) for (8081 .. 8085);
$t->waitforfile($dns_ready) or die "Can't start dns daemon";

if ($has_unix) {
	for (1 .. 50) {
		last if -S $unix_path;
		select undef, undef, undef, 0.1;
	}
}

$t->plan(20);

###############################################################################

like(front_get(8080), qr/405 Not Allowed/, 'non-CONNECT rejected');

my ($s, $headers) = tunnel_connect(8080, 'ignored.example:443');
like($headers, qr/^HTTP\/1\.1 200 Connection Established/m,
	'literal CONNECT status');
unlike($headers, qr/^Content-Length:/mi,
	'successful CONNECT omits Content-Length header');
is(tunnel_read($s), 'READY literal 127.0.0.1', 'literal greeting');
tunnel_write($s, 'hello');
is(tunnel_read($s), 'literal:hello', 'literal data');

my $big = 'x' x 16384;
tunnel_write($s, $big);
is(tunnel_read($s), 'literal:' . $big, 'literal big data');
close $s;

my ($sp, $hp) = tunnel_connect(8080, 'ignored.example:443',
	message => "pipelined" . CRLF);
like($hp, qr/^HTTP\/1\.1 200 Connection Established/m,
	'literal CONNECT status with pipelined data');
is(tunnel_read($sp), 'READY literal 127.0.0.1', 'literal pipelined greeting');
is(tunnel_read($sp), 'literal:pipelined', 'literal pipelined data');
tunnel_write($sp, 'after');
is(tunnel_read($sp), 'literal:after', 'literal post-handshake data');
close $sp;

my ($sd) = tunnel_connect(8086, '127.0.0.1:' . port(8082),
	host => 'wrong.example:1111');
is(tunnel_read($sd), 'READY second 127.0.0.1',
	'default tunnel_pass uses authority host and port');
close $sd;

my ($sn) = tunnel_connect(8087, 'ignored.example:443',
	extra_headers => [ 'X-Tunnel-Allow: allow' ]);
is(tunnel_read($sn), 'READY second 127.0.0.1',
	'allow_upstream permits tunnel');
close $sn;

my ($sdenied, $hdenied) = tunnel_connect(8088, 'ignored.example:443');
like($hdenied, qr/^HTTP\/1\.1 403 Forbidden/m,
	'allow_upstream denial returns 403');
close $sdenied if $sdenied;

my ($se) = tunnel_connect(8090, 'ignored.example:443');
is(tunnel_read($se), 'READY second 127.0.0.1',
	'connect error retries next peer');
close $se;

my ($serr, $herr) = tunnel_connect(8091, 'ignored.example:443');
like($herr, qr/^HTTP\/1\.1 502 Bad Gateway/m,
	'connect error without retry returns 502');
close $serr if $serr;

SKIP: {
	skip '127.0.0.2 and 127.0.0.3 local addresses required', 2
		unless $has_bind_retry;

	my ($sb1) = tunnel_connect(8092, 'ignored.example:443');
	is(tunnel_read($sb1), 'READY bind-two 127.0.0.3',
		'dynamic bind reevaluated on retry');
	close $sb1;

	my ($sb2) = tunnel_connect(8093, 'ignored.example:443');
	is(tunnel_read($sb2), 'READY bind-two 127.0.0.2',
		'bind without dynamic keeps initial address');
	close $sb2;
}

SKIP: {
	skip 'IO::Socket::UNIX not installed', 1 unless $has_unix;

	my ($su) = tunnel_connect(8094, 'ignored.example:443');
	is(tunnel_read($su), 'READY unix unix', 'unix socket tunnel works');
	close $su;
}

my ($sr) = tunnel_connect(8095, 'ignored.example:443',
	extra_headers => [ 'X-Tunnel-Target: example.net:' . port(8085) ]);
is(tunnel_read($sr), 'READY resolved 127.0.0.1', 'resolver tunnel works');
close $sr;

my ($snr, $hnr) = tunnel_connect(8096, 'ignored.example:443',
	extra_headers => [ 'X-Tunnel-Target: example.net:' . port(8085) ]);
like($hnr, qr/^HTTP\/1\.1 502 Bad Gateway/m,
	'missing resolver returns 502');
close $snr if $snr;

###############################################################################

sub front_get {
	my ($port) = @_;

	my $socket = IO::Socket::INET->new(
		Proto => 'tcp',
		PeerAddr => '127.0.0.1:' . port($port),
	)
		or die "Can't connect to nginx: $!\n";

	return http(<<EOF, socket => $socket);
GET / HTTP/1.0
Host: localhost

EOF
}

sub tunnel_connect {
	my ($port, $authority, %opts) = @_;

	my $s = IO::Socket::INET->new(
		Proto => 'tcp',
		PeerAddr => '127.0.0.1:' . port($port),
	)
		or die "Can't connect to nginx: $!\n";

	my $req = 'CONNECT ' . $authority . ' HTTP/1.1' . CRLF
		. 'Host: ' . ($opts{host} || 'localhost') . CRLF;

	if ($opts{extra_headers}) {
		$req .= join('', map { $_ . CRLF } @{$opts{extra_headers}});
	}

	$req .= CRLF;

	$req .= $opts{message} if defined $opts{message};

	tunnel_send_raw($s, $req);

	my ($headers, $rest) = tunnel_read_headers($s);

	${*$s}->{_tunnel_private} = { b => $rest || '' };

	return ($s, $headers);
}

sub tunnel_read_headers {
	my ($s) = @_;
	my $buf = '';

	eval {
		local $SIG{ALRM} = sub { die "timeout\n" };
		alarm(8);

		while ($buf !~ /\x0d?\x0a\x0d?\x0a/ms) {
			my $chunk = '';
			my $n = $s->sysread($chunk, 4096);
			die "unexpected eof\n" unless $n;
			$buf .= $chunk;
		}

		alarm(0);
	};
	alarm(0);
	die $@ if $@;

	$buf =~ /(.*?\x0d?\x0a\x0d?\x0a)(.*)/ms
		or die "Can't parse headers\n";

	return ($1, $2);
}

sub tunnel_send_raw {
	my ($s, $data) = @_;

	local $SIG{PIPE} = 'IGNORE';

	while (length $data) {
		my $n = $s->syswrite($data);
		die "Can't write to tunnel socket: $!\n" unless $n;
		substr($data, 0, $n, '');
	}
}

sub tunnel_write {
	my ($s, $line) = @_;
	tunnel_send_raw($s, $line . CRLF);
}

sub tunnel_read {
	my ($s) = @_;
	my $line = tunnel_getline($s);
	$line =~ s/\x0d?\x0a$// if defined $line;
	return $line;
}

sub tunnel_getline {
	my ($s) = @_;

	${*$s}->{_tunnel_private} ||= { b => '' };
	my $ctx = ${*$s}->{_tunnel_private};

	if ($ctx->{b} =~ /^(.*?\x0a)(.*)/ms) {
		$ctx->{b} = $2;
		return $1;
	}

	$s->blocking(0);

	while (IO::Select->new($s)->can_read(3)) {
		my $chunk = '';
		my $n = $s->sysread($chunk, 4096);
		last unless $n;

		$ctx->{b} .= $chunk;

		if ($ctx->{b} =~ /^(.*?\x0a)(.*)/ms) {
			$ctx->{b} = $2;
			return $1;
		}
	}

	return;
}

sub tunnel_daemon {
	my ($port, $label) = @_;

	my $server = IO::Socket::INET->new(
		Proto => 'tcp',
		LocalAddr => '127.0.0.1',
		LocalPort => $port,
		Listen => 5,
		Reuse => 1,
	)
		or die "Can't create listening socket: $!\n";

	local $SIG{PIPE} = 'IGNORE';

	while (my $client = $server->accept()) {
		$client->autoflush(1);
		handle_tunnel_client($client, $label,
			eval { $client->peerhost() } || 'unknown');
	}
}

sub tunnel_unix_daemon {
	my ($path, $label) = @_;

	unlink $path if -e $path;

	my $server = IO::Socket::UNIX->new(
		Proto => 'tcp',
		Local => $path,
		Listen => 5,
		Reuse => 1,
	)
		or die "Can't create listening socket: $!\n";

	local $SIG{PIPE} = 'IGNORE';

	while (my $client = $server->accept()) {
		$client->autoflush(1);
		handle_tunnel_client($client, $label, 'unix');
	}
}

sub handle_tunnel_client {
	my ($client, $label, $peer) = @_;

	print $client "READY $label $peer" . CRLF;

	while (my $line = <$client>) {
		$line =~ s/\x0d?\x0a$//;
		print $client $label . ':' . $line . CRLF;
	}

	$client->close();
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
