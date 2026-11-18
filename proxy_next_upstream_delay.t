#!/usr/bin/perl

# (C) Nginx, Inc.

# Tests for http proxy module, proxy_next_upstream_delay directive.

###############################################################################

use warnings;
use strict;

use Test::More;
use Time::HiRes qw(time);
use IO::Select;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/http proxy rewrite ssi/);

$t->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    upstream u {
        server 127.0.0.1:8081;
        server 127.0.0.1:8082;
    }

    upstream dead {
        server 127.0.0.1:8083;
        server 127.0.0.1:8084;
    }

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        root %%TESTDIR%%;

        location = /delay {
            proxy_pass http://u/all/;
            proxy_next_upstream http_404 no_live;
            proxy_next_upstream_tries 3;
            proxy_next_upstream_delay 1s;
            proxy_intercept_errors on;
            error_page 404 = /status;
        }

        location = /status {
            return 200 "x${upstream_status}x";
        }

        location = /sub {
            proxy_pass http://dead;
            proxy_next_upstream error no_live;
            proxy_next_upstream_tries 3;
            proxy_next_upstream_delay 100ms;
        }

        location / {
            ssi on;
        }
    }

    server {
        listen       127.0.0.1:8081;
        listen       127.0.0.1:8082;
        server_name  localhost;

        location /all/ {
            return 404;
        }
    }
}

EOF

$t->write_file('sub.html', '<!--#include virtual="/sub" -->');

$t->try_run('no proxy_next_upstream_delay')->plan(5);

###############################################################################

# 3 tries over 2 peers and the delay is fired once

my $t1 = time();
like(http_get('/delay'), qr/x404, 404, 404x/, 'delayed retry');

my $elapsed = time() - $t1;
cmp_ok($elapsed, '>=', 1, 'delay applied');
cmp_ok($elapsed, '<', 2, 'delay applied once');

# the pending retry timer has to be removed when the request finalized

my $s = http_get('/delay', start => 1);
select undef, undef, undef, 0.2;
close $s;
select undef, undef, undef, 1.2;

like(http_get('/delay'), qr/x404, 404, 404x/, 'client abort during delay');

# a subrequest finalized from the retry timer has to wake up its parent

like(get_slow('/sub.html'), qr/502 Bad Gateway/, 'subrequest parent woken');

###############################################################################

sub get_slow {
	my ($uri) = @_;

	my $s = http_get($uri, start => 1);

	unless (IO::Select->new($s)->can_read(2)) {
		close $s;
		return '';
	}

	return http_end($s);
}

###############################################################################
