#!/usr/bin/perl

# (C) Vadim Zhestikov
# (C) Nginx, Inc.

# Tests for nginx mail auth_http module, Auth-Wait responses.

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

my $t = Test::Nginx->new()->has(qw/mail pop3 http rewrite/)->plan(6)
	->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;
worker_shutdown_timeout 10ms;

events {
}

mail {
    auth_http  http://127.0.0.1:8080/mail/auth;

    server {
        listen     127.0.0.1:8110;
        protocol   pop3;
    }
}

http {
    %%TEST_GLOBALS_HTTP%%

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        location = /mail/auth {
            set $reply ERROR;
            set $wait 1;
            set $pass "";
            set $ok 0;

            if (-f %%TESTDIR%%/ok) {
                set $ok 1;
            }

            set $userpass "$http_auth_user:$http_auth_pass:$ok";

            if ($userpass = 'test@example.com:wait:0') {
                set $reply WAIT;
            }

            if ($userpass = 'test@example.com:wait:1') {
                set $reply OK;
                set $pass secret;
            }

            if ($http_auth_pass ~ wait([0-9])) {
                set $reply WAIT;
                set $wait $1;
            }

            if ($http_auth_pass ~ error([0-9])) {
                set $wait $1;
            }

            add_header Auth-Status $reply;
            add_header Auth-Server 127.0.0.1;
            add_header Auth-Port %%PORT_8111%%;
            add_header Auth-Pass $pass;
            add_header Auth-Wait $wait;
            return 204;
        }
    }
}

EOF

$t->run_daemon(\&Test::Nginx::POP3::pop3_test_daemon);
$t->run()->waitforsocket('127.0.0.1:' . port(8111));

###############################################################################

# "Auth-Status: WAIT": the request to the auth server is repeated
# after the pause, the client gets no response in between

my $s = Test::Nginx::POP3->new();
$s->read();
$s->send('USER test@example.com');
$s->read();
$s->send('PASS wait');

ok(!$s->can_read(), 'auth wait');

$t->write_file('ok', '');
$s->ok('auth after wait');

# an error with Auth-Wait: the error is sent after the pause
# and the session stays open

$s = Test::Nginx::POP3->new();
$s->read();
$s->send('USER test@example.com');
$s->read();
$s->send('PASS error1');
$s->check(qr/^-ERR/, 'error after wait');
$s->send('USER test@example.com');
$s->ok('session kept after error');

# worker shutdown during a longer pause, in both states:
# the sessions are closed at once, not when the pause ends

my $s1 = Test::Nginx::POP3->new();
$s1->read();
$s1->send('USER test@example.com');
$s1->read();
$s1->send('PASS error3');

my $s2 = Test::Nginx::POP3->new();
$s2->read();
$s2->send('USER test@example.com');
$s2->read();
$s2->send('PASS wait3');

$t->reload();

TODO: {
local $TODO = 'not yet' unless $t->has_version('1.31.10');

ok($s1->can_read(1), 'closed on shutdown, error pause');
ok($s2->can_read(1), 'closed on shutdown, wait pause');

}

###############################################################################
