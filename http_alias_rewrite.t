#!/usr/bin/perl

# (C) David Carlier

# Tests for alias with rewrite.

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

my $t = Test::Nginx->new()->has(qw/http rewrite/)
	->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    log_format test '$status $request_uri $request_filename';

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        location /redirect/ {
            alias %%TESTDIR%%/dir/;
            access_log %%TESTDIR%%/redirect_$host.log test;

            rewrite ^/redirect/x$ http://example.com/ redirect;
        }

        location /if/ {
            alias %%TESTDIR%%/dir/;
            access_log %%TESTDIR%%/if_$host.log test;

            if ($arg_r) {
                rewrite ^ http://example.com/ permanent;
            }
        }

        location /rewritten/ {
            alias %%TESTDIR%%/dir/;

            rewrite ^/rewritten/.*$ /x;
            return 200 "fn=$request_filename";
        }
    }
}

EOF

mkdir($t->testdir() . '/dir');
$t->write_file('dir/file', 'SEE-THIS');

# alias with a rewritten URI is rejected and logged at the "alert" level

$t->todo_alerts();

$t->run()->plan(9);

###############################################################################

my $d = $t->testdir();

like(http_get('/redirect/x'), qr/ 302 /, 'redirect');
like(http_get('/redirect/file'), qr/SEE-THIS/, 'no redirect');
like(http_get('/if/x?r=1'), qr/ 301 /, 'redirect in if');
like(http_get('/if/file'), qr/SEE-THIS/, 'no redirect in if');

like(http_get('/rewritten/long/uri'), qr/fn=$/, 'rewritten uri not mapped');

$t->stop();

is($t->read_file('redirect_localhost.log'),
	"302 /redirect/x $d/dir/x\n200 /redirect/file $d/dir/file\n",
	'redirect logged');
is($t->read_file('if_localhost.log'),
	"301 /if/x?r=1 $d/dir/x\n200 /if/file $d/dir/file\n",
	'redirect in if logged');

my $log = $t->read_file('error.log');

unlike($log, qr/\[alert\].*GET \/(redirect|if)\//, 'redirect no alert');
like($log, qr/\[alert\].*GET \/rewritten\//, 'rewritten uri alert');

###############################################################################
