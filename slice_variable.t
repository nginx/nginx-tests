#!/usr/bin/perl

# (C) Nginx, Inc.

# Tests for slice filter, variables in the slice directive.

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

my $t = Test::Nginx->new()->has(qw/http proxy slice map/)->plan(13);

$t->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    map $arg_size $size {
        default   2;
        "4"       4;
        "1k"      1k;
        "0"       0;
        "bad"     nonsense;
        "neg"     -1;
        "empty"   "";
    }

    slice $size;

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        location /proxy/ {
            slice $size;

            proxy_pass    http://127.0.0.1:8081/;

            proxy_set_header   Range  $slice_range;
        }

        location /inherit/ {
            proxy_pass    http://127.0.0.1:8081/;

            proxy_set_header   Range  $slice_range;
        }

        location /override/ {
            slice 4;

            proxy_pass    http://127.0.0.1:8081/;

            proxy_set_header   Range  $slice_range;
        }
    }

    server {
        listen       127.0.0.1:8081;
        server_name  localhost;

        add_header Accept-Ranges bytes;

        location / { }
    }
}

EOF

$t->write_file('t', '0123456789abcdef');
$t->run();

###############################################################################

my $r;

# valid values

$r = get('/proxy/t?size=2', 'Range: bytes=3-4');
like($r, qr/ 206 /, 'size 2 - 206 partial reply');
like($r, qr/^34$/m, 'size 2 - correct content');

$r = get('/proxy/t?size=4', 'Range: bytes=3-4');
like($r, qr/ 206 /, 'size 4 - 206 partial reply');
like($r, qr/^34$/m, 'size 4 - correct content');

$r = get('/proxy/t?size=1k', 'Range: bytes=3-4');
like($r, qr/ 206 /, 'size 1k - 206 partial reply');
like($r, qr/^34$/m, 'size 1k - correct content');

# zero disables slicing

like(get('/proxy/t?size=0', 'Range: bytes=3-4'),
	qr/ 200 .*0123456789abcdef$/ms, 'size 0 - slicing disabled');

# invalid values fall back to the default, that is, slicing is disabled

like(get('/proxy/t?size=bad', 'Range: bytes=3-4'),
	qr/ 200 .*0123456789abcdef$/ms, 'size invalid - slicing disabled');

like(get('/proxy/t?size=neg', 'Range: bytes=3-4'),
	qr/ 200 .*0123456789abcdef$/ms, 'size negative - slicing disabled');

like(get('/proxy/t?size=empty', 'Range: bytes=3-4'),
	qr/ 200 .*0123456789abcdef$/ms, 'size empty - slicing disabled');

like($t->read_file('error.log'), qr/invalid size "nonsense"/,
	'size invalid - error logged');

# inherited and overridden

$r = get('/inherit/t?size=4', 'Range: bytes=3-4');
like($r, qr/^34$/m, 'inherited - correct content');

$r = get('/override/t?size=0', 'Range: bytes=3-4');
like($r, qr/^34$/m, 'overridden - correct content');

###############################################################################

sub get {
	my ($url, $extra) = @_;
	return http(<<EOF);
GET $url HTTP/1.1
Host: localhost
Connection: close
$extra

EOF
}

###############################################################################
