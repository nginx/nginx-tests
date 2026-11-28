#!/usr/bin/perl

# Tests for server_header directive.

use warnings;
use strict;

use Test::More;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/http rewrite/)
        ->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    server_header off;

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        location = /http_off {
            return 200;
        }

        location = /on {
            server_header on;
            return 200;
        }

        location = /off {
            server_header off;
            return 200;
        }

        location = /inherit {
            return 200;
        }

        location = /override {
            server_header on;
            return 200;
        }
    }
        server {
        listen       127.0.0.1:8080;
        server_name  server-level;
        server_header on;

        location / {
            return 200;
        }
    }
}

EOF

$t->run()->plan(6);

like(http_get_server('/', 'server-level'), qr/^nginx(?:\/|$)/,
    'server header enabled at server level');

is(http_get_server('/http_off'), undef,
    'server header disabled by http directive');

like(http_get_server('/on'), qr/^nginx(?:\/|$)/,
    'server header on');

is(http_get_server('/off'), undef,
    'server header off');

is(http_get_server('/inherit'), undef,
    'server header inherited from http');

like(http_get_server('/override'), qr/^nginx(?:\/|$)/,
    'server header overridden in location');

sub http_get_server {
    my ($url, $host) = @_;

    my $response = defined $host
        ? http("GET $url HTTP/1.0\r\nHost: $host\r\n\r\n")
        : http_get($url);

    return $response =~ /^Server:\s*(.+?)\x0d?$/mi
        ? $1 : undef;
}
