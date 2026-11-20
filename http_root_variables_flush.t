#!/usr/bin/perl

# (C) Nginx, Inc.

# Tests for non-cacheable variables flushed by variables in "root",
# with proxy_set_header, fastcgi_param, scgi_param, and uwsgi_param;
# non-cacheable variables in proxy_pass are evaluated anew.

# Evaluating $document_root with variables in "root" used to flush all
# non-cacheable variables, so a non-cacheable variable evaluated earlier
# in the same script could change its length between the length and the
# copy pass of the upstream request, see GitHub issue #1194.

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

my $t = Test::Nginx->new()
	->has(qw/http rewrite map proxy fastcgi scgi uwsgi/);

$t->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    # each evaluation sees the previous value of $capture,
    # so the value grows: "prefix:", "prefix:prefix:", ...

    map prefix:$capture $volatile {
        volatile;
        ~(?<capture>.*)  $capture;
    }

    map $uri $volatile_uri {
        volatile;
        default  $uri;
    }

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        root %%TESTDIR%%/$server_name;

        set $capture "";

        location /proxy {
            proxy_pass http://127.0.0.1:8081/;
            proxy_set_header X-Volatile $volatile;
            proxy_set_header X-Root $document_root;
        }

        location /proxy/control {
            proxy_pass http://127.0.0.1:8081/;
            proxy_set_header X-Root $document_root;
            proxy_set_header X-Volatile $volatile;
        }

        location /rewrite {
            set $unused $volatile_uri;
            rewrite ^ /rewritten break;
            proxy_pass http://127.0.0.1:8081$volatile_uri;
        }

        # nothing listens on port 8082: 502 means
        # the request to the upstream was created

        location /fastcgi {
            fastcgi_pass 127.0.0.1:8082;
            fastcgi_param VOLATILE $volatile;
            fastcgi_param ROOT $document_root;
        }

        location /scgi {
            scgi_pass 127.0.0.1:8082;
            scgi_param VOLATILE $volatile;
            scgi_param ROOT $document_root;
        }

        location /uwsgi {
            uwsgi_pass 127.0.0.1:8082;
            uwsgi_param VOLATILE $volatile;
            uwsgi_param ROOT $document_root;
        }
    }

    server {
        listen       127.0.0.1:8081;
        server_name  localhost;

        location / {
            add_header X-Volatile $http_x_volatile;
            add_header X-URI $uri;
            return 204;
        }
    }
}

EOF

$t->run()->plan(6);

###############################################################################

like(http_get('/proxy/control'), qr/X-Volatile: prefix:\x0d/,
	'proxy volatile after root');
like(http_get('/rewrite'), qr!X-URI: /rewritten!, 'proxy_pass volatile');

TODO: {
local $TODO = 'not yet' unless $t->has_version('1.31.11');

like(http_get('/proxy'), qr/X-Volatile: prefix:\x0d/,
	'proxy volatile before root');
like(http_get('/fastcgi'), qr/ 502 /, 'fastcgi volatile before root');
like(http_get('/scgi'), qr/ 502 /, 'scgi volatile before root');
like(http_get('/uwsgi'), qr/ 502 /, 'uwsgi volatile before root');

}

$t->todo_alerts() unless $t->has_version('1.31.11');

###############################################################################
