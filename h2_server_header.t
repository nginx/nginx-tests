#!/usr/bin/perl

# Tests for HTTP/2 protocol with server_header directive.

use warnings;
use strict;

use Test::More;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;
use Test::Nginx::HTTP2;

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()
    ->has(qw/http http_v2 rewrite/)
    ->plan(3)
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

        http2 on;

        location /default {
            return 200;
        }

        location /on {
            server_header on;
            return 200;
        }

        location /off {
            server_header off;
            return 200;
        }
    }
}

EOF

$t->run();

is(header_server('/default'), undef,
    'http2 server header disabled by http directive');

like(header_server('/on'), qr/^nginx(?:\/|$)/,
    'http2 server header enabled in location');

is(header_server('/off'), undef,
    'http2 server header disabled in location');

sub header_server {
    my ($path) = @_;

    my $s = Test::Nginx::HTTP2->new();
    my $sid = $s->new_stream({ path => $path });
    my $frames = $s->read(all => [{ sid => $sid, fin => 1 }]);

    my ($frame) = grep { $_->{type} eq 'HEADERS' } @$frames;

    return $frame->{headers}->{'server'};
}
