#!/usr/bin/perl

# (C) Nginx, Inc.

# Tests for map variable with regex capture used in rewrite
# replacement.  When a map variable whose value contains a $1
# reference from a map regex pattern is used in a rewrite
# replacement, the rewrite's $1 must expand using the rewrite
# regex capture, not the map regex capture (ticket #357).

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

my $t = Test::Nginx->new()->has(qw/http map rewrite/)->plan(6);

$t->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    map $http_test_lang $lang {
        default rm;
        ~^(de|fr)$  $1;
    }

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        rewrite ^(/test)$ $1/$lang/;

        location / {
            return 200 "ok\n";
        }
    }
}

EOF

$t->run();

###############################################################################

like(http_get_with_headers('GET /test', 'Test-Lang: en'), qr/^ok$/m,
     'default map value, no map regex');
like(http_get_with_headers('GET /test', 'Test-Lang: it'), qr/^ok$/m,
     'literal map value, no map regex');
like(http_get_with_headers('GET /test', 'Test-Lang: de'), qr/^ok$/m,
     'map regex capture $1, rewrite $1 is not overwritten - de');
like(http_get_with_headers('GET /test', 'Test-Lang: fr'), qr/^ok$/m,
     'map regex capture $1, rewrite $1 is not overwritten - fr');
like(http_get('/'), qr/^ok$/m,
     'no rewrite on different URI');
like(http_get_with_headers('GET /test', 'Test-Lang: es'), qr/^ok$/m,
     'default value with map regex non-match');


sub http_get_with_headers {
    my ($url, $header) = @_;
    my $r = http(<<"EOF");
$url HTTP/1.0
Host: localhost
Connection: close
$header

EOF
    return $r;
}

###############################################################################
