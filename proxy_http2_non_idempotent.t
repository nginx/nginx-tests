#!/usr/bin/perl

# (C) Zhidao HONG
# (C) Nginx, Inc.

# Tests for HTTP/2 proxy backend with proxy_next_upstream non_idempotent.

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

my $t = Test::Nginx->new()->has(qw/http proxy rewrite upstream_keepalive http_v2/)
	->plan(8);

$t->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    upstream u {
        server 127.0.0.1:8081 max_fails=0;
        server 127.0.0.1:8082 max_fails=0;
    }

    upstream uk {
        server 127.0.0.1:8081 max_fails=0;
        server 127.0.0.1:8082 max_fails=0;
        keepalive 10;
    }

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        add_header X-IP $upstream_addr always;

        location / {
            proxy_pass http://u;
            proxy_http_version 2;
            proxy_next_upstream error timeout http_500;
        }

        location /non {
            proxy_pass http://u;
            proxy_http_version 2;
            proxy_next_upstream error timeout http_500 non_idempotent;
        }

        location /keepalive {
            proxy_pass http://uk;
            proxy_http_version 2;
            proxy_next_upstream error timeout;
        }
    }

    server {
        listen       127.0.0.1:8081;
        server_name  localhost;

        http2 on;

        location / {
            return 500;
        }

        location /500 {
            return 500 SEE-THIS;
        }

        location /keepalive/establish {
            return 204;
        }
    }

    server {
        listen       127.0.0.1:8082;
        server_name  localhost;

        http2 on;

        location / {
            return 500;
        }

        location /500 {
            return 500 SEE-THIS;
        }

        location /keepalive/drop {
            return 500;
        }
    }
}

EOF

$t->run();

###############################################################################

# non-idempotent requests should not be retried by default
# if a request has been sent to a backend

like(http_get('/'), qr/x-ip: (\S+), (\S+)\x0d?$/mi, 'get');
like(http_post('/'), qr/x-ip: (\S+)\x0d?$/mi, 'post');

# non-idempotent requests should not be retried by default,
# in particular, not emit builtin error page due to next upstream

like(http_get('/500'), qr/x-ip: (\S+), (\S+).*SEE-THIS/si, 'get 500');
like(http_post('/500'), qr/x-ip: (\S++)(?! ).*SEE-THIS/si, 'post 500');

# with "proxy_next_upstream non_idempotent" there is no
# difference between idempotent and non-idempotent requests,
# non-idempotent requests are retried as usual

like(http_get('/non'), qr/x-ip: (\S+), (\S+)\x0d?$/mi, 'get non_idempotent');
like(http_post('/non'), qr/x-ip: (\S+), (\S+)\x0d?$/mi, 'post non_idempotent');

# cached connections follow the same rules

like(http_get('/keepalive/establish'), qr/204 No Content/mi, 'keepalive');
like(http_post('/keepalive/drop'), qr/x-ip: (\S+)\x0d?$/mi, 'keepalive post');

###############################################################################

sub http_post {
	my ($uri, %extra) = @_;
	my $cl = $extra{cl} || 0;

	http(<<"EOF");
POST $uri HTTP/1.0
Content-Length: $cl

EOF
}

###############################################################################
