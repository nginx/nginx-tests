#!/usr/bin/perl

# Tests for HTTP/1.x optional whitespace around header field values.

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

my $t = Test::Nginx->new()->has(qw/http/)->plan(7)
	->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        add_header X-Host $http_host always;
        add_header X-Test $http_x_test always;

        location / {
            return 204;
        }
    }
}

EOF

$t->run();

###############################################################################

my $r;

$r = http("GET / HTTP/1.1" . CRLF
	. "Host:\tlocalhost" . CRLF
	. "Connection: close" . CRLF . CRLF);

like($r, qr/ 204 /, 'leading HTAB before header value');
like($r, qr/X-Host: localhost\x0d?\x0a/, 'leading HTAB stripped');

$r = http("GET / HTTP/1.1" . CRLF
	. "Host: localhost\t" . CRLF
	. "X-Test:\tsee-this\t" . CRLF
	. "Connection: close" . CRLF . CRLF);

like($r, qr/X-Host: localhost\x0d?\x0a/, 'trailing HTAB stripped');
like($r, qr/X-Test: see-this\x0d?\x0a/, 'leading and trailing HTAB stripped');

###############################################################################

# Transfer-Encoding and Content-Length OWS coverage.
#
# Tab characters around header values are HTTP/1.x OWS (RFC 9112).  After
# OWS is stripped, Content-Length and Transfer-Encoding must be parsed
# against the same byte stream as nginx's downstream parsers would see.

like(http("GET / HTTP/1.1" . CRLF
	. "Host: localhost" . CRLF
	. "Content-Length: \t0\t" . CRLF
	. "Connection: close" . CRLF . CRLF),
	qr/ 204 /, 'Content-Length with HTAB padding is accepted');

like(http("POST / HTTP/1.1" . CRLF
	. "Host: localhost" . CRLF
	. "Content-Length:\t0" . CRLF
	. "Connection: close" . CRLF . CRLF),
	qr/ 204 /, 'Content-Length with leading HTAB is accepted');

like(http("GET / HTTP/1.1" . CRLF
	. "Host: localhost" . CRLF
	. "Transfer-Encoding:\tchunked\t" . CRLF
	. "Connection: close" . CRLF . CRLF),
	qr/ 204 /, 'Transfer-Encoding chunked with HTAB padding is accepted');

###############################################################################
