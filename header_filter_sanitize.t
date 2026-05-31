#!/usr/bin/perl

# Tests for sanitizing runtime-expanded add_header/add_trailer values when
# they contain CRLF that would otherwise create new field syntax.

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

my $t = Test::Nginx->new()->has(qw/http rewrite/)->plan(6);

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

        location /resp-header/ {
            add_header X-Original-Path $uri always;
            return 200 "ok\n";
        }

        location /resp-trailer/ {
            add_trailer X-Original-Path $uri always;
            return 200 "ok\n";
        }
    }
}

EOF

$t->run();

###############################################################################

my $crlf = '%0d%0aX-Injected:%20yes';
my $response;

$response = get('/resp-header/' . $crlf);
like($response, qr/200 OK/, 'add_header keeps response after sanitizing CRLF');
like($response, qr/X-Original-Path: \/resp-header\//,
    'add_header still emits response header');
unlike($response, qr/\x0d\x0aX-Injected:\s*yes/i,
    'add_header does not emit injected response header');

$response = get('/resp-trailer/' . $crlf);
like($response, qr/200 OK/, 'add_trailer keeps response after sanitizing CRLF');
like($response, qr/X-Original-Path: \/resp-trailer\//,
    'add_trailer still emits trailer');
unlike($response, qr/\x0d\x0aX-Injected:\s*yes/i,
    'add_trailer does not emit injected trailer header');

###############################################################################

sub get {
    my ($uri) = @_;
    http(<<EOF);
GET $uri HTTP/1.1
Host: localhost
Connection: close

EOF
}

###############################################################################