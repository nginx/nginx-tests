#!/usr/bin/perl

# Tests that a response field value which cannot be sent does not leave the
# client without a reply.
#
# A client that gets no bytes back cannot tell a rejected request from a
# broken network, so whatever nginx decides to do with the offending bytes,
# the request has to be answered.
#
# RFC 9110 section 5.6.3 describes what a sender does with optional
# whitespace in a field value: it should not generate optional whitespace
# except as needed to overwrite invalid or unwanted protocol elements during
# in-place message filtering.  Overwriting is the operation; dropping the
# connection is not one of them.

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

my $t = Test::Nginx->new()->has(qw/http/)->plan(2);

$t->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        location /echo/ {
            add_header X-Echo $uri always;
            return 200 "ok";
        }
    }
}

EOF

$t->run();

###############################################################################

# a path ending in a space is an ordinary request

my $r = http_get('/echo/v%20');

like($r, qr{^HTTP/1\.[01] \d\d\d}, 'the request is answered');

TODO: {
local $TODO = 'the value is sent as it is';

unlike($r, qr/^X-Echo:.*[ \t]\r?$/m,
	'the field value carries no trailing whitespace');

}

###############################################################################
