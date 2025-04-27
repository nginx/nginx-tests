#!/usr/bin/perl

# (C) Maxim Dounin

# Tests for nginx dav module with chunked request body.

###############################################################################

use warnings;
use strict;

use Test::More;
use Socket qw/ CRLF /;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/http dav/)->plan(6);

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

        client_header_buffer_size 1k;
        client_body_buffer_size 2k;

        location / {
            dav_methods PUT;
        }
    }
}

EOF

$t->run();

###############################################################################

my $r;

$r = http(<<EOF);
PUT /file HTTP/1.1\r
Host: localhost\r
Connection: close\r
Transfer-Encoding: chunked\r
\r
a\r
1234567890\r
0\r
\r
EOF

like($r, qr/201 Created.*(Content-Length|\x0d\0a0\x0d\x0a)/ms, 'put chunked');
is($t->read_file('file'), '1234567890', 'put content');

$r = http(<<EOF);
PUT /file HTTP/1.1\r
Host: localhost\r
Connection: close\r
Transfer-Encoding: chunked\r
\r
0\r
\r
EOF

like($r, qr/204 No Content/, 'put chunked empty');
is($t->read_file('file'), '', 'put empty content');

my $body = ('a' . CRLF . '1234567890' . CRLF) x 1024 . '0' . CRLF . CRLF;

$r = http(<<EOF);
PUT /file HTTP/1.1\r
Host: localhost\r
Connection: close\r
Transfer-Encoding: chunked\r
\r
$body
EOF

like($r, qr/204 No Content/, 'put chunked big');
is($t->read_file('file'), '1234567890' x 1024, 'put big content');

###############################################################################
