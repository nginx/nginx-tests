#!/usr/bin/perl

# (C) Maxim Dounin

# Tests for nginx gzip filter module HTAB handling in Accept-Encoding.
#
# Verifies that a horizontal tab (HTAB, 0x09) is treated as whitespace
# between comma-separated tokens in the Accept-Encoding request header,
# matching the SP behavior already supported by ngx_http_gzip_accept_encoding().
#
# Per RFC 9110 §5.6.3, the Accept-Encoding field value is a "#rule" list of
# codings; the surrounding field grammar (RFC 9110 §5.6.2) defines optional
# whitespace as SP / HTAB. The companion HTTP/1 parser already accepts HTAB
# alongside SP at the field-value boundary (RFC 9112 §2.2), and Vadim's
# nginx#1577 taught the multi-header parser to accept HTAB as well. The
# gzip_accept_encoding helper in ngx_http_core_module.c carries its own
# boundary check, so it must be updated to match.
#
# The gap is the single-character path that runs after the gzip token has
# been matched: the switches in the function only carry case ' ' (space) and
# exit on the bare comma that ends the list, so HTAB falls into the default
# branch and the encoding is rejected. Test 1 below covers the case where
# the comma is hit before HTAB, which therefore works correctly today and
# is held as a regression sentinel.
#
# Code PR: nginx/nginx#<companion>

###############################################################################

use warnings;
use strict;

use Test::More;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx qw/ :DEFAULT :gzip /;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/http gzip/)->plan(7);

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

        location / {
            gzip on;
        }
    }
}

EOF

$t->write_file('index.html', 'X' x 64);

$t->run();

###############################################################################

# Baseline: SP / no whitespace between tokens is recognised.
like(http_ae('gzip, deflate'), qr/Content-Encoding: gzip/,
    'gzip enabled with SP between tokens');

like(http_ae('gzip,deflate'), qr/Content-Encoding: gzip/,
    'gzip enabled with no whitespace between tokens');

# Regression sentinel: HTAB after the comma is recognised because the comma
# ends the token scan before HTAB is inspected.
like(http_ae("gzip,\tdeflate"), qr/Content-Encoding: gzip/,
    'gzip enabled with HTAB after comma');

# RFC 9110 §5.6.2 requires comma separators between elements; whitespace
# alone is not enough. The patch accepts HTAB as whitespace but does not
# change the rejection of malformed input that lacks a comma.
unlike(http_ae("gzip\tdeflate"), qr/Content-Encoding: gzip/,
    'malformed Accept-Encoding without comma is rejected');

TODO: {
local $TODO = 'gzip accept_encoding does not recognise HTAB';

# HTAB before the comma: Accept-Encoding: gzip\t,deflate.
like(http_ae("gzip\t,deflate"), qr/Content-Encoding: gzip/,
    'gzip enabled with HTAB before comma');

# HTAB inside the quantity: gzip;\tq=0.5.
like(http_ae("gzip;\tq=0.5"), qr/Content-Encoding: gzip/,
    'gzip enabled with HTAB before q-value');

# HTAB after the q-value, before the comma: gzip;q=0.5\t,deflate.
like(http_ae("gzip;q=0.5\t,deflate"), qr/Content-Encoding: gzip/,
    'gzip enabled with HTAB after q-value before comma');

}

###############################################################################

sub http_ae {
	my ($ae) = @_;
	return http(<<EOF);
GET / HTTP/1.1
Host: localhost
Connection: close
Accept-Encoding: $ae

EOF
}

###############################################################################
