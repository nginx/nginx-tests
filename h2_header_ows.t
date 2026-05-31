#!/usr/bin/perl

# Tests for HTTP/2 optional whitespace around header field values.

###############################################################################

use warnings;
use strict;

use Test::More;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;
use Test::Nginx::HTTP2;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/http http_v2/)->plan(6)
	->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    http2 on;

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

		add_header X-Test $http_x_test always;
		add_header X-Test-Decorated "[$http_x_test]" always;

        location / {
            return 204;
        }
    }
}

EOF

$t->run();

###############################################################################

my ($s, $sid, $frames, $frame);

$s = Test::Nginx::HTTP2->new();
$sid = $s->new_stream({ headers => [
	{ name => ':method', value => 'GET', mode => 0 },
	{ name => ':scheme', value => 'http', mode => 0 },
	{ name => ':path', value => '/', mode => 0 },
	{ name => ':authority', value => 'localhost', mode => 1 },
	{ name => 'x-test', value => "\tsee-this\t", mode => 2 }]});
$frames = $s->read(all => [{ sid => $sid, fin => 1 }]);

($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
is($frame->{headers}->{':status'}, 204, 'HTTP/2 header value with HTAB');
is($frame->{headers}->{'x-test'}, 'see-this',
	'HTTP/2 header value HTAB stripped');

$sid = $s->new_stream({ headers => [
	{ name => ':method', value => 'GET', mode => 0 },
	{ name => ':scheme', value => 'http', mode => 0 },
	{ name => ':path', value => '/', mode => 0 },
	{ name => ':authority', value => 'localhost', mode => 1 },
	{ name => 'x-test', value => " see-this ", mode => 2 }]});
$frames = $s->read(all => [{ sid => $sid, fin => 1 }]);

($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
is($frame->{headers}->{':status'}, 204, 'HTTP/2 header value with spaces');
is($frame->{headers}->{'x-test'}, 'see-this',
	'HTTP/2 header value spaces stripped');

$sid = $s->new_stream({ headers => [
	{ name => ':method', value => 'GET', mode => 0 },
	{ name => ':scheme', value => 'http', mode => 0 },
	{ name => ':path', value => '/', mode => 0 },
	{ name => ':authority', value => 'localhost', mode => 1 },
	{ name => 'x-test', value => " \t ", mode => 2 }]});
$frames = $s->read(all => [{ sid => $sid, fin => 1 }]);

($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
is($frame->{headers}->{':status'}, 204, 'HTTP/2 whitespace-only header value');
is($frame->{headers}->{'x-test-decorated'}, '[]',
	'HTTP/2 whitespace-only header value stripped');

###############################################################################