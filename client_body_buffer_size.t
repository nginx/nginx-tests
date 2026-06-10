#!/usr/bin/perl

# (C) Nginx, Inc.

# Tests for client_body_buffer_size configuration validation.

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

my $t = Test::Nginx->new()->has(qw/http/)->plan(10);

my $d = $t->testdir;

# Empty error.log so DESTROY-time "no alerts" / "no sanitizer errors"
# checks have a file to read; nginx is invoked with -t only and never
# starts as a daemon in this test.

$t->write_file('error.log', '');

###############################################################################

# zero value rejected at location scope

$t->write_file_expand('zero-location.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        location / {
            client_body_buffer_size 0;
        }
    }
}

EOF

my $out = `$Test::Nginx::NGINX -t -p $d/ -c zero-location.conf -e error.log 2>&1`;
isnt($? >> 8, 0, 'zero value at location scope rejected');
like($out, qr/\[emerg\].*client body buffer size cannot be zero/,
	'emerg message at location scope');

# zero value rejected at server scope

$t->write_file_expand('zero-server.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        client_body_buffer_size 0;
    }
}

EOF

$out = `$Test::Nginx::NGINX -t -p $d/ -c zero-server.conf -e error.log 2>&1`;
isnt($? >> 8, 0, 'zero value at server scope rejected');
like($out, qr/\[emerg\].*client body buffer size cannot be zero/,
	'emerg message at server scope');

# zero value rejected at http scope

$t->write_file_expand('zero-http.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    client_body_buffer_size 0;

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;
    }
}

EOF

$out = `$Test::Nginx::NGINX -t -p $d/ -c zero-http.conf -e error.log 2>&1`;
isnt($? >> 8, 0, 'zero value at http scope rejected');
like($out, qr/\[emerg\].*client body buffer size cannot be zero/,
	'emerg message at http scope');

# zero value with a size suffix also rejected ("0k" parses to 0)

$t->write_file_expand('zero-suffix.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        location / {
            client_body_buffer_size 0k;
        }
    }
}

EOF

$out = `$Test::Nginx::NGINX -t -p $d/ -c zero-suffix.conf -e error.log 2>&1`;
isnt($? >> 8, 0, 'zero value with size suffix rejected');
like($out, qr/\[emerg\].*client body buffer size cannot be zero/,
	'emerg message with size suffix');

# valid values accepted

$t->write_file_expand('valid.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        location / {
            client_body_buffer_size 1;
        }

        location /default {
        }

        location /size {
            client_body_buffer_size 8k;
        }
    }
}

EOF

$out = `$Test::Nginx::NGINX -t -p $d/ -c valid.conf -e error.log 2>&1`;
is($? >> 8, 0, 'valid values accepted');
unlike($out, qr/\[emerg\]/, 'no emerg for valid values');

###############################################################################
