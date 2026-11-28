#!/usr/bin/perl

# (C) Elijah Zupancic
# (C) F5, Inc.

# Tests for automatic redirects in locations ending with a slash
# with proxy_pass, fastcgi_pass, uwsgi_pass and scgi_pass, with and
# without variables, including preserving query arguments.

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

my $t = Test::Nginx->new()->has(qw/http proxy fastcgi uwsgi scgi rewrite/)
	->plan(18)->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        set $backend 127.0.0.1:8081;

        location /proxy/ {
            proxy_pass http://127.0.0.1:8081;
        }

        location /proxy-var/ {
            proxy_pass http://$backend;
        }

        location /fastcgi/ {
            fastcgi_pass 127.0.0.1:8081;
        }

        location /fastcgi-var/ {
            fastcgi_pass $backend;
        }

        location /uwsgi/ {
            uwsgi_pass 127.0.0.1:8081;
        }

        location /uwsgi-var/ {
            uwsgi_pass $backend;
        }

        location /scgi/ {
            scgi_pass 127.0.0.1:8081;
        }

        location /scgi-var/ {
            scgi_pass $backend;
        }
    }
}

EOF

$t->run();

###############################################################################

like(http_get('/proxy'), qr!301 .*Location: http://localhost:\d+/proxy/!s,
	'proxy_pass');
like(http_get('/proxy-var'),
	qr!301 .*Location: http://localhost:\d+/proxy-var/!s,
	'proxy_pass with variables');
like(http_get('/fastcgi'),
	qr!301 .*Location: http://localhost:\d+/fastcgi/!s,
	'fastcgi_pass');
like(http_get('/fastcgi-var'),
	qr!301 .*Location: http://localhost:\d+/fastcgi-var/!s,
	'fastcgi_pass with variables');
like(http_get('/uwsgi'), qr!301 .*Location: http://localhost:\d+/uwsgi/!s,
	'uwsgi_pass');
like(http_get('/scgi'), qr!301 .*Location: http://localhost:\d+/scgi/!s,
	'scgi_pass');

TODO: {
local $TODO = 'not yet' unless $t->has_version('1.31.9');

like(http_get('/uwsgi-var'),
	qr!301 .*Location: http://localhost:\d+/uwsgi-var/!s,
	'uwsgi_pass with variables');
like(http_get('/scgi-var'),
	qr!301 .*Location: http://localhost:\d+/scgi-var/!s,
	'scgi_pass with variables');

like(http_get('/uwsgi-var?a=b'),
	qr!301 .*Location: http://localhost:\d+/uwsgi-var/\?a=b\x0d?$!ms,
	'uwsgi_pass with variables and args');
like(http_get('/scgi-var?a=b'),
	qr!301 .*Location: http://localhost:\d+/scgi-var/\?a=b\x0d?$!ms,
	'scgi_pass with variables and args');

}

# requests with the trailing slash are not redirected

unlike(http_get('/proxy/'), qr/301/, 'proxy_pass no redirect');
unlike(http_get('/proxy-var/'), qr/301/,
	'proxy_pass with variables no redirect');
unlike(http_get('/fastcgi/'), qr/301/, 'fastcgi_pass no redirect');
unlike(http_get('/fastcgi-var/'), qr/301/,
	'fastcgi_pass with variables no redirect');
unlike(http_get('/uwsgi/'), qr/301/, 'uwsgi_pass no redirect');
unlike(http_get('/uwsgi-var/'), qr/301/,
	'uwsgi_pass with variables no redirect');
unlike(http_get('/scgi/'), qr/301/, 'scgi_pass no redirect');
unlike(http_get('/scgi-var/'), qr/301/,
	'scgi_pass with variables no redirect');

###############################################################################
