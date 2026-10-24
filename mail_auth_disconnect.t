#!/usr/bin/perl

# (C) Vadim Zhestikov
# (C) Nginx, Inc.

# Tests for nginx mail module, client disconnect during authentication.

###############################################################################

use warnings;
use strict;

use Test::More;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;
use Test::Nginx::POP3;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

local $SIG{PIPE} = 'IGNORE';

my $t = Test::Nginx->new()->has(qw/mail pop3 http/)->plan(1)
	->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

mail {
    auth_http  http://127.0.0.1:8080/auth;

    server {
        listen     127.0.0.1:8110;
        protocol   pop3;
        pop3_auth  plain;
    }
}

http {
    %%TEST_GLOBALS_HTTP%%

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        location = /auth {
            root %%TESTDIR%%;
            add_header Auth-Status "WAIT";
            add_header Auth-Wait 2;
        }
    }
}

EOF

$t->write_file('auth', '');
$t->run();

###############################################################################

# after an Auth-Wait response the proxy pauses before the next step; a client
# that disconnects during the pause must not keep the session alive

my $s = Test::Nginx::POP3->new();
$s->read();
$s->send('USER test@example.com');
$s->read();
$s->send('PASS secret');

# close the client while the proxy is in the Auth-Wait pause
$s->socket()->close();

my $found = '';
for (1 .. 50) {
	$found = $t->read_file('error.log');
	last if $found =~ /client closed connection/;
	select undef, undef, undef, 0.1;
}

# the fix is not in a release yet; once it is, guard with
# $t->has_version() for the release that carries it
TODO: {
local $TODO = 'not yet';

like($found, qr/client closed connection/, 'session closed on disconnect');

}

###############################################################################
