#!/usr/bin/perl

# (C) Patrik Wall

# Tests for upstream socket buffer directives in HTTP modules.

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

my $t = Test::Nginx->new()->has(qw/http proxy/)->has_daemon('ss');

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

        location /off {
            proxy_pass http://127.0.0.1:8081;
            proxy_socket_rcvbuf off;
            proxy_socket_sndbuf off;
        }

        location /max {
            proxy_pass http://127.0.0.1:8081;
            proxy_socket_rcvbuf max;
            proxy_socket_sndbuf max;
        }

        location /size {
            proxy_pass http://127.0.0.1:8081;
            proxy_socket_rcvbuf 256k;
            proxy_socket_sndbuf 128k;
        }

        location /hold {
            proxy_pass http://127.0.0.1:8081;
            proxy_socket_rcvbuf 256k;
            proxy_socket_sndbuf 128k;
        }

        location /default {
            proxy_pass http://127.0.0.1:8081;
        }
    }
}

EOF

$t->run_daemon(\&http_daemon, $t->testdir());
$t->try_run('no upstream socket buffer directives')->plan(14);
$t->waitforsocket('127.0.0.1:' . port(8081));

###############################################################################

like(http_get('/off'), qr/SEE-THIS/, 'proxy_socket_*buf off');
like(http_get('/max'), qr/SEE-THIS/, 'proxy_socket_*buf max');
like(http_get('/size'), qr/SEE-THIS/, 'proxy_socket_*buf size');
like(http_get('/default'), qr/SEE-THIS/, 'no directive (default off)');

my $s = http(<<EOF, start => 1);
GET /hold HTTP/1.0
Host: localhost

EOF

die "no held proxy connection" unless $s;
die "upstream connection not held"
	unless $t->waitforfile($t->testdir() . '/hold.ready');

my ($rb, $tb) = ss_socket_buffers(port(8081));
cmp_ok($rb, '>=', 256 * 1024, 'proxy_socket_rcvbuf seen by ss');
cmp_ok($tb, '>=', 128 * 1024, 'proxy_socket_sndbuf seen by ss');

$s->close();

SKIP: {
skip 'no fastcgi', 1 unless $t->has_module('fastcgi');

like(config_ok($t, "fastcgi_pass 127.0.0.1:8082;\n"
	. "            fastcgi_socket_rcvbuf 256k;\n"
	. "            fastcgi_socket_sndbuf 128k;"),
	qr/syntax is ok/, 'fastcgi_socket_*buf parsed');

}

SKIP: {
skip 'no grpc', 1 unless $t->has_module('grpc');

like(config_ok($t, "grpc_pass 127.0.0.1:8083;\n"
	. "            grpc_socket_rcvbuf 256k;\n"
	. "            grpc_socket_sndbuf 128k;"),
	qr/syntax is ok/, 'grpc_socket_*buf parsed');

}

SKIP: {
skip 'no memcached/map', 1
	unless $t->has_module('memcached') && $t->has_module('map');

like(config_ok($t, "memcached_pass 127.0.0.1:8084;\n"
	. "            memcached_socket_rcvbuf 256k;\n"
	. "            memcached_socket_sndbuf 128k;",
	"    map \$uri \$memcached_key {\n"
	. "        default \$uri;\n"
	. "    }\n"),
	qr/syntax is ok/, 'memcached_socket_*buf parsed');

}

SKIP: {
skip 'no scgi', 1 unless $t->has_module('scgi');

like(config_ok($t, "scgi_pass 127.0.0.1:8085;\n"
	. "            scgi_socket_rcvbuf 256k;\n"
	. "            scgi_socket_sndbuf 128k;"),
	qr/syntax is ok/, 'scgi_socket_*buf parsed');

}

SKIP: {
skip 'no uwsgi', 1 unless $t->has_module('uwsgi');

like(config_ok($t, "uwsgi_pass 127.0.0.1:8086;\n"
	. "            uwsgi_socket_rcvbuf 256k;\n"
	. "            uwsgi_socket_sndbuf 128k;"),
	qr/syntax is ok/, 'uwsgi_socket_*buf parsed');

}

like(config_fails($t, 'proxy_socket_rcvbuf 0;'), qr/invalid value "0"/,
	'proxy_socket_rcvbuf zero');

like(config_fails($t, 'proxy_socket_sndbuf -1;'), qr/invalid value "-1"/,
	'proxy_socket_sndbuf negative');

like(config_fails($t, "proxy_socket_rcvbuf 4k;\n"
	. "            proxy_socket_rcvbuf 8k;"),
	qr/"proxy_socket_rcvbuf" directive is duplicate/,
	'proxy_socket_rcvbuf duplicate');

###############################################################################

sub config_fails {
	my ($t, $directives) = @_;

	return config_test($t, 'nginx-bad.conf', $directives);
}

sub config_ok {
	my ($t, $directives, $http) = @_;

	return config_test($t, 'nginx-ok.conf', $directives, $http);
}

sub config_test {
	my ($t, $name, $directives, $http) = @_;

	$http = '' unless defined $http;

	$t->write_file_expand($name, <<EOF);
%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

$http
    server {
        listen       127.0.0.1:8090;
        server_name  localhost;

        location / {
            $directives
        }
    }
}

EOF

	my $d = $t->testdir();
	local $?;
	return `$Test::Nginx::NGINX -t -p $d/ -c $name -e error.log 2>&1`;
}

sub ss_socket_buffers {
	my ($port) = @_;

	for (1 .. 50) {
		my $out = `ss -tnpemi 2>&1`;

		foreach my $entry (split /\n(?=ESTAB)/, $out) {
			next unless $entry =~
				/^ESTAB\s+\S+\s+\S+\s+\S+\s+127\.0\.0\.1:$port\b/m;
			next unless $entry =~ /skmem:\(([^)]*)\)/;

			my $skmem = $1;
			my ($rb) = $skmem =~ /(?:^|,)rb(\d+)/;
			my ($tb) = $skmem =~ /(?:^|,)tb(\d+)/;

			return ($rb, $tb) if defined $rb && defined $tb;
		}

		select undef, undef, undef, 0.1;
	}

	return (0, 0);
}

sub http_daemon {
	my ($dir) = @_;

	my $server = IO::Socket::INET->new(
		Proto => 'tcp',
		LocalAddr => '127.0.0.1:' . port(8081),
		Listen => 5,
		Reuse => 1
	)
		or die "Can't create listening socket: $!\n";

	local $SIG{PIPE} = 'IGNORE';

	while (my $client = $server->accept()) {
		$client->autoflush(1);

		my $request = '';

		while (<$client>) {
			$request .= $_;
			last if (/^\x0d?\x0a?$/);
		}

		if ($request =~ m!^GET /hold !m) {
			open my $fh, '>', "$dir/hold.ready"
				or die "Can't create hold.ready: $!\n";
			close $fh;

			1 while $client->sysread(my $buf, 1024);
			close $client;
			next;
		}

		print $client <<'EOF';
HTTP/1.1 200 OK
Connection: close

SEE-THIS
EOF

		close $client;
	}
}

###############################################################################
