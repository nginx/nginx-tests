#!/usr/bin/perl

# (C) Sergey Kandaurov
# (C) Nginx, Inc.

# Tests for the proxy_pass directive with HTTP/2 and variables.

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

my $t = Test::Nginx->new()->has(qw/http http_ssl http_v2 proxy rewrite/)
	->has_daemon('openssl')->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    upstream u {
        server 127.0.0.1:8081;
    }

    resolver 127.0.0.1:%%PORT_8982_UDP%%;

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        location / {
            proxy_pass http://$host:%%PORT_8081%%;
            proxy_http_version 2.0;
        }

        location /http {
            proxy_pass http://$host:%%PORT_8081%%;
            proxy_http_version 2.0;
        }

        location /https {
            proxy_pass https://$host:%%PORT_8082%%;
            proxy_http_version 2.0;
        }

        location /arg {
            proxy_pass $arg_b;
            proxy_http_version 2.0;
        }
    }

    server {
        listen       127.0.0.1:8081 http2;
        listen       127.0.0.1:8082 http2 ssl;
        server_name  localhost;

        ssl_certificate_key localhost.key;
        ssl_certificate localhost.crt;

        location / {
            return 200 $http_host;
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

$t->run_daemon(\&dns_daemon, port(8982), $t);

# suppress deprecation warning

open OLDERR, ">&", \*STDERR; close STDERR;
$t->run()->plan(5);
open STDERR, ">&", \*OLDERR;

$t->waitforfile($t->testdir . '/' . port(8982));

###############################################################################

like(http_get('/basic'), qr/200 OK/, 'no scheme');
like(http_get('/http'), qr/200 OK/, 'http scheme');

SKIP: {
skip 'OpenSSL too old', 1
	if $t->has_module('OpenSSL')
	and not $t->has_feature('openssl:1.0.2');

like(http_get('/https'), qr/200 OK/, 'https scheme');

}

like(http_get('/arg?b=http://127.0.0.1:' . port(8081)), qr/200 OK/, 'addrs');
like(http_get('/arg?b=http://u'), qr/200 OK/, 'no_port');

###############################################################################

sub reply_handler {
	my ($recv_data) = @_;

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
	if ($name eq 'localhost' && $type == A) {
		push @rdata, rd_addr($ttl, '127.0.0.1');
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
	my ($port, $t) = @_;

	my ($data, $recv_data);
	my $socket = IO::Socket::INET->new(
		LocalAddr => '127.0.0.1',
		LocalPort => $port,
		Proto => 'udp',
	)
		or die "Can't create listening socket: $!\n";

	# signal we are ready

	open my $fh, '>', $t->testdir() . '/' . $port;
	close $fh;

	while (1) {
		$socket->recv($recv_data, 65536);
		$data = reply_handler($recv_data);
		$socket->send($data);
	}
}

###############################################################################
