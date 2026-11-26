#!/usr/bin/perl

# (C) Nginx, Inc.

# Tests for upstream least_time balancer module, "bucket" and "smooth"
# parameters.

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

my $t = Test::Nginx->new()
	->has(qw/http proxy upstream_least_time rewrite map/)
	->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

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

    map $server_port:$arg_r $map_rate {
        %%PORT_8081%%:1    500;

        default            0;
    }

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        location /u1/ {
            proxy_pass http://u1/;
        }
        location /u2/ {
            proxy_pass http://u2/;
        }
    }

    server {
        listen       127.0.0.1:8081;
        listen       127.0.0.1:8082;
        server_name  localhost;

        keepalive_requests 1;

        location / {
            add_header X-Port $server_port;
            set $limit_rate $map_rate;
        }
    }
}

EOF

$t->write_file('index.html', '0123456789' x 204);
$t->try_run('no least_time bucket and smooth')->plan(2);

###############################################################################

my (@s);
my @ports = my ($p1, $p2) = (port(8081), port(8082));

# response times within the same bucket are considered equal,
# so the slower peer is still selected

@s = map { http_get('/u1/?r=1', start => 1) } (1 .. 6);
http_end $_ for @s;

like(many('/u1/', 10), qr/$p1: [1-9], $p2: [1-9]/, 'bucket');

# smoothed response time, faster peer wins

@s = map { http_get('/u2/?r=1', start => 1) } (1 .. 6);
http_end $_ for @s;

is(many('/u2/', 10), "$p2: 10", 'smooth');

###############################################################################

sub many {
	my ($uri, $count) = @_;
	my %ports;

	for (1 .. $count) {
		if (http_get($uri) =~ /X-Port: (\d+)/) {
			$ports{$1} = 0 unless defined $ports{$1};
			$ports{$1}++;
		}
	}

	my @keys = map { my $p = $_; grep { $p == $_ } keys %ports } @ports;
	return join ', ', map { $_ . ": " . $ports{$_} } @keys;
}

###############################################################################
