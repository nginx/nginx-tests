#!/usr/bin/perl

# (C) Maxim Dounin

# Tests for nginx ssi module, stub output.

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

my $t = Test::Nginx->new()->has(qw/http proxy ssi/)->plan(4)
	->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        location / {
            ssi on;
        }

        location = /empty {
            # static
        }

        location = /error404 {
            # static 404
        }

        location = /proxy404 {
            proxy_pass http://127.0.0.1:8081;
            proxy_intercept_errors on;
            error_page 404 /error404;
        }

        location = /not_empty {
            proxy_pass http://127.0.0.1:8081;
        }
    }

    server {
        listen       127.0.0.1:8081;
        server_name  localhost;
    }
}

EOF

$t->write_file('empty.html',
	'<!--#block name="fallback" -->fallback<!--#endblock -->' .
	':<!--#include virtual="/empty" stub="fallback" -->:');

$t->write_file('error.html',
	'<!--#block name="fallback" -->fallback<!--#endblock -->' .
	':<!--#include virtual="/error404" stub="fallback" -->:');

$t->write_file('proxy_error.html',
	'<!--#block name="fallback" -->fallback<!--#endblock -->' .
	':<!--#include virtual="/proxy404" stub="fallback" -->:');

$t->write_file('postponed.html',
	'<!--#block name="fallback" -->fallback<!--#endblock -->' .
	':<!--#include virtual="/not_empty" -->' .
	':<!--#include virtual="/empty" stub="fallback" -->:');

$t->write_file('empty', '');
$t->write_file('not_empty', 'not empty');

$t->run();

###############################################################################

like(http_get('/empty.html'), qr/:fallback:/, 'ssi stub empty');
like(http_get('/error.html'), qr/:fallback:/, 'ssi stub error');
like(http_get('/proxy_error.html'), qr/:fallback:/, 'ssi stub proxied error');

TODO: {
local $TODO = 'not yet' unless $t->has_version('1.31.5');

like(http_get('/postponed.html'), qr/:not empty:fallback:/s,
	'ssi stub postponed');

}

###############################################################################
