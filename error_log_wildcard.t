#!/usr/bin/perl

# (C) Vadim Zhestikov
# (C) Nginx, Inc.

# Tests for error_log with servers sharing a wildcard listening socket.

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

my $t = Test::Nginx->new()->has(qw/http/);

plan(skip_all => 'listen on wildcard address')
	unless $ENV{TEST_NGINX_UNSAFE};

$t->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    server {
        listen       127.0.0.1:8080 proxy_protocol;
        server_name  localhost;

        error_log address.log info;
    }

    server {
        listen       %%PORT_8080%%;
        server_name  localhost;

        error_log wildcard.log info;
    }
}

EOF

$t->run()->plan(2);

###############################################################################

# broken PROXY protocol header, logged before a request is created

http("GARBAGE\r\n\r\n");

TODO: {
local $TODO = 'not yet';

like($t->read_file('address.log'), qr/broken header/,
	'address-specific server log');
unlike($t->read_file('wildcard.log'), qr/broken header/,
	'wildcard server log');

}

###############################################################################
