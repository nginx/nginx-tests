#!/usr/bin/perl

# (C) Eugene Grebenschikov
# (C) Nginx, Inc.

# Tests for $request_length with discarded request body.

###############################################################################

use warnings;
use strict;

use Test::More;
use Socket qw/ CRLF /;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/http proxy rewrite/);
plan(skip_all => 'not yet') unless $t->has_version('1.31.4');

$t->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    log_format rl '$uri $request_length';

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        location /discard {
            access_log %%TESTDIR%%/discard.log rl;
            return 200;
        }

        location /read {
            access_log %%TESTDIR%%/read.log rl;
            proxy_pass http://127.0.0.1:8081;
        }
    }

    server {
        listen       127.0.0.1:8081;
        server_name  localhost;

        location / {
            return 200;
        }
    }
}

EOF

$t->run()->plan(7);

###############################################################################

my ($r, $rl, $body);

$body = '0123456789';
$r = 'PUT /discard HTTP/1.1' . CRLF
	. 'Host: localhost' . CRLF
	. 'Connection: close' . CRLF
	. 'Content-Length: ' . length($body) . CRLF . CRLF
	. $body;
http($r);
my $rl_cl = length($r);

$body = 'X' x 256;
$r = 'PUT /discard HTTP/1.1' . CRLF
	. 'Host: localhost' . CRLF
	. 'Connection: close' . CRLF
	. 'Transfer-Encoding: chunked' . CRLF . CRLF
	. sprintf('%x', length($body)) . CRLF . $body . CRLF
	. '0' . CRLF . CRLF;
http($r);
my $rl_chunked = length($r);

$body = 'X' x 8192;
$r = 'PUT /discard HTTP/1.1' . CRLF
	. 'Host: localhost' . CRLF
	. 'Connection: close' . CRLF
	. 'Content-Length: ' . length($body) . CRLF . CRLF
	. $body;
http($r);
my $rl_large = length($r);

$body = 'A' x 10;
my $pr1 = 'PUT /discard HTTP/1.1' . CRLF
	. 'Host: localhost' . CRLF
	. 'Content-Length: ' . length($body) . CRLF . CRLF
	. $body;

$body = 'B' x 10;
my $pr2 = 'PUT /discard HTTP/1.1' . CRLF
	. 'Host: localhost' . CRLF
	. 'Connection: close' . CRLF
	. 'Content-Length: ' . length($body) . CRLF . CRLF
	. $body;
http($pr1 . $pr2);

$body = '0123456789';
$r = 'PUT /read HTTP/1.1' . CRLF
	. 'Host: localhost' . CRLF
	. 'Connection: close' . CRLF
	. 'Content-Length: ' . length($body) . CRLF . CRLF
	. $body;
http($r);
my $rl_read = length($r);

$r = 'GET /discard HTTP/1.1' . CRLF
	. 'Host: localhost' . CRLF
	. 'Connection: close' . CRLF . CRLF;
http($r);
my $rl_nobody = length($r);

$t->stop();

my @lines = split /\n/, $t->read_file('discard.log');

is($lines[0], "/discard $rl_cl", 'discarded Content-Length body');
is($lines[1], "/discard $rl_chunked", 'discarded chunked body');
is($lines[2], "/discard $rl_large", 'discarded large body');
is($lines[3], '/discard ' . length($pr1),
	'pipelined discarded body - first request');
is($lines[4], '/discard ' . length($pr2),
	'pipelined discarded body - second request');
is($lines[5], "/discard $rl_nobody", 'no body');
is($t->read_file('read.log'), "/read $rl_read\n", 'body read via proxy');

###############################################################################
