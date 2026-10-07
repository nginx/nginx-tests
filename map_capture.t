#!/usr/bin/perl

# (C) Nginx, Inc.

# Tests for interaction between map module with regex and location
# regex captures.  A map variable that uses a regex pattern must not
# overwrite the request-level capture state ($1, $2, ...) set by the
# location regex.

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

my $t = Test::Nginx->new()->has(qw/http map rewrite/)->plan(5);

$t->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    map $server_protocol $myvar {
        ~/.+$    'mapped';
        default  'na';
    }

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        location ~* ^/(.+)/(.+)$ {
            return 200 "1:$1 2:$2 mv:$myvar\n";
        }

        location / {
            return 200 "ok\n";
        }
    }
}

EOF

$t->run();

###############################################################################

like(http_get('/foo/bar'), qr/^1:foo 2:bar mv:mapped$/m,
     'map regex does not overwrite location captures');
like(http_get('/first/second'), qr/^1:first 2:second mv:mapped$/m,
     'different URI captures preserved');
like(http_get('/a/b'), qr/^1:a 2:b mv:mapped$/m,
     'short URI captures preserved');
like(http_get('/'), qr/^ok$/m,
     'normal location unaffected');

# verify captures work with static map value (not via regex)
like(http_get('/no/map'), qr/^1:no 2:map mv:mapped$/m,
     'captures work with map variable in response');

###############################################################################
