#!/usr/bin/perl

# (c) Eugene Grebenschikov

# Tests for error reporting when an upstream connection fails.

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

my $t = Test::Nginx->new()->has(qw/http proxy/)
	->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    log_format test "$status:$upstream_connect_time";

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        access_log %%TESTDIR%%/test.log test;

        location / {
            proxy_pass http://127.0.0.1:8081;
        }

        location /body {
            proxy_pass http://127.0.0.1:8081;
        }
    }
}

EOF

$t->run()->plan(5);

###############################################################################

like(http_get('/'), qr/^HTTP\/1.. 502 /, 'connection refused - 502');

my $r = http(<<"EOF");
POST /body HTTP/1.0
Host: localhost
Content-Length: 10

0123456789
EOF

like($r, qr/^HTTP\/1.. 502 /, 'connection refused with body - 502');

my $log = $t->read_file('error.log');

like($log, qr/connect\(\) .*failed .*while connecting to upstream/,
	'connect() failed reported');

like($log, qr/\(\d+: .*Connection .*refused.*\)/i, 'ECONNREFUSED preserved');

unlike($t->read_file('test.log'), qr/^502:(?!-)/m,
	'no connect time on failure');

###############################################################################
