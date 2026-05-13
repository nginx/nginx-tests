#!/usr/bin/perl

# (C) Patrik Wall

# Tests for proxy_socket_rcvbuf and proxy_socket_sndbuf in stream proxy.

###############################################################################

use warnings;
use strict;

use Test::More;

use IO::Select;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;
use Test::Nginx::Stream qw/ stream /;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/stream/)->has_daemon('ss')
	->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

stream {
    %%TEST_GLOBALS_STREAM%%

    server {
        listen      127.0.0.1:8080;
        proxy_pass  127.0.0.1:8084;
        proxy_socket_rcvbuf off;
        proxy_socket_sndbuf off;
    }

    server {
        listen      127.0.0.1:8081;
        proxy_pass  127.0.0.1:8084;
        proxy_socket_rcvbuf max;
        proxy_socket_sndbuf max;
    }

    server {
        listen      127.0.0.1:8082;
        proxy_pass  127.0.0.1:8084;
        proxy_socket_rcvbuf 256k;
        proxy_socket_sndbuf 128k;
    }

    server {
        listen      127.0.0.1:8083;
        proxy_pass  127.0.0.1:8084;
    }
}

EOF

$t->run_daemon(\&stream_daemon);
$t->try_run('no proxy_socket_*buf')->plan(9);
$t->waitforsocket('127.0.0.1:' . port(8084));

###############################################################################

# Each directive form successfully proxies a message.  The daemon closes the
# connection after seeing 'close', so nginx has no lingering connections at
# SIGQUIT time.

is(stream('127.0.0.1:' . port(8080))->io('close', length => 5), 'close',
	'proxy_socket_*buf off');

is(stream('127.0.0.1:' . port(8081))->io('close', length => 5), 'close',
	'proxy_socket_*buf max');

is(stream('127.0.0.1:' . port(8082))->io('close', length => 5), 'close',
	'proxy_socket_*buf size');

is(stream('127.0.0.1:' . port(8083))->io('close', length => 5), 'close',
	'no directive (default off)');

my $s = stream('127.0.0.1:' . port(8082));
$s->write('hold');

my ($rb, $tb) = ss_socket_buffers(port(8084));
cmp_ok($rb, '>=', 256 * 1024, 'stream proxy_socket_rcvbuf seen by ss');
cmp_ok($tb, '>=', 128 * 1024, 'stream proxy_socket_sndbuf seen by ss');

like(config_fails($t, 'proxy_socket_rcvbuf 0;'), qr/invalid value "0"/,
	'stream proxy_socket_rcvbuf zero');

like(config_fails($t, 'proxy_socket_sndbuf -1;'), qr/invalid value "-1"/,
	'stream proxy_socket_sndbuf negative');

like(config_fails($t, "proxy_socket_rcvbuf 4k;\n"
	. "        proxy_socket_rcvbuf 8k;"),
	qr/"proxy_socket_rcvbuf" directive is duplicate/,
	'stream proxy_socket_rcvbuf duplicate');

###############################################################################

sub config_fails {
	my ($t, $directives) = @_;

	my $name = 'nginx-bad.conf';

	$t->write_file_expand($name, <<EOF);
%%TEST_GLOBALS%%

daemon off;

events {
}

stream {
    %%TEST_GLOBALS_STREAM%%

    server {
        listen      127.0.0.1:8090;
        proxy_pass  127.0.0.1:8084;
        $directives
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

sub stream_daemon {
	my $server = IO::Socket::INET->new(
		Proto => 'tcp',
		LocalAddr => '127.0.0.1:' . port(8084),
		Listen => 5,
		Reuse => 1
	)
		or die "Can't create listening socket: $!\n";

	my $sel = IO::Select->new($server);

	local $SIG{PIPE} = 'IGNORE';

	while (my @ready = $sel->can_read) {
		foreach my $fh (@ready) {
			if ($server == $fh) {
				my $new = $fh->accept;
				$new->autoflush(1);
				$sel->add($new);

			} elsif (stream_handle_client($fh)) {
				$sel->remove($fh);
				$fh->close;
			}
		}
	}
}

sub stream_handle_client {
	my ($client) = @_;

	log2c("(new connection $client)");

	$client->sysread(my $buf, 65536) or return 1;

	log2i("$client $buf");

	log2o("$client $buf");

	$client->syswrite($buf);

	return $buf =~ /close/;
}

sub log2i { Test::Nginx::log_core('|| <<', @_); }
sub log2o { Test::Nginx::log_core('|| >>', @_); }
sub log2c { Test::Nginx::log_core('||', @_); }

###############################################################################
