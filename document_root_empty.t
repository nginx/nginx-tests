#!/usr/bin/perl

# (C) Vinod Dandge

# Tests for empty variable root.

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

my $t = Test::Nginx->new()->has(qw/http rewrite map/)->plan(2)
	->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    map $host $webroot {
        default "";
    }

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        root  $webroot;

        location / {
        }

        location /docroot {
            set  $dr  $document_root;
            return  200 "$dr\n";
        }
    }
}

EOF

$t->write_file('robots.txt', 'robots');
my $d = $t->testdir() . '/';

# With MALLOC_PERTURB_=208, glibc fills freshly allocated memory with '/',
# so an empty root used to be treated as an absolute path.

local $ENV{MALLOC_PERTURB_} = 208;

$t->run();

###############################################################################

my $ok = 0;
for (1 .. 100) {
	$ok++ if http_get('/robots.txt') =~ / 200 /;
}

is($ok, 100, 'empty variable root maps to prefix');

like(http_get('/docroot'), qr/200 OK.*\r\n\r\n\Q$d\E\n$/s,
	'$document_root with empty root');

###############################################################################
