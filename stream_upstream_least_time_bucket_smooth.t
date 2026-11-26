#!/usr/bin/perl

# (C) Nginx, Inc.

# Stream tests for upstream least_time balancer module, "bucket" and
# "smooth" parameters.

###############################################################################

use warnings;
use strict;

use Test::More;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx qw/ :DEFAULT http_end /;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

plan(skip_all => 'win32') if $^O eq 'MSWin32';

my $t = Test::Nginx->new()->has(qw/http stream stream_upstream_least_time/)
	->has(qw/rewrite map/);

$t->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

stream {
    %%TEST_GLOBALS_STREAM%%

    # separate upstreams for sane statistics

    upstream u1 {
        least_time last_byte bucket=5s;
        server 127.0.0.1:8081;
        server 127.0.0.1:8082;
    }

    upstream u2 {
        least_time last_byte smooth=10s;
        server 127.0.0.1:8081;
        server 127.0.0.1:8082;
    }

    server {
        listen      127.0.0.1:8085;
        proxy_pass  u1;
    }

    server {
        listen      127.0.0.1:8086;
        proxy_pass  u2;
    }
}

http {
    %%TEST_GLOBALS_HTTP%%

    map $server_port:$arg_r $map_rate {
        %%PORT_8081%%:1    500;

        default            0;
    }

    server {
        listen       127.0.0.1:8081;
        listen       127.0.0.1:8082;
        server_name  localhost;

        add_header X-Port $server_port;
        set $limit_rate $map_rate;

        location / { }
    }
}

EOF

$t->write_file('index.html', '0123456789' x 204);
$t->try_run('no least_time bucket and smooth')->plan(2);

###############################################################################

my (@s);
my @ports = my ($p1, $p2) = (port(8081), port(8082));

# last byte times within the same bucket are considered equal,
# so the slower peer is still selected

my $pb = port(8085);

@s = map {
	http_get('/?r=1', start => 1, socket => getconn("127.0.0.1:$pb"))
} (1 .. 6);
http_end $_ for @s;

like(many('/', 10, "127.0.0.1:$pb"), qr/$p1: [1-9], $p2: [1-9]/, 'bucket');

# smoothed last byte time, faster peer wins

my $ps = port(8086);

@s = map {
	http_get('/?r=1', start => 1, socket => getconn("127.0.0.1:$ps"))
} (1 .. 6);
http_end $_ for @s;

is(many('/', 10, "127.0.0.1:$ps"), "$p2: 10", 'smooth');

###############################################################################

sub getconn {
	my $peer = shift;
	my $s = IO::Socket::INET->new(
		Proto => 'tcp',
		PeerAddr => $peer
	)
		or die "Can't connect to nginx: $!\n";

	return $s;
}

sub many {
	my ($uri, $count, $peer) = @_;
	my %ports;

	for (1 .. $count) {
		if (http_get($uri, socket => getconn($peer)) =~ /X-Port: (\d+)/)
		{
			$ports{$1} = 0 unless defined $ports{$1};
			$ports{$1}++;
		}

		select undef, undef, undef, 0.04;
	}

	my @keys = map { my $p = $_; grep { $p == $_ } keys %ports } @ports;
	return join ', ', map { $_ . ": " . $ports{$_} } @keys;
}

###############################################################################
