#!/usr/bin/perl

# (C) Vadim Zhestikov
# (C) Nginx, Inc.

# Tests for HTTP/3 protocol, error_log in a server selected by SNI.

###############################################################################

use warnings;
use strict;

use Test::More;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;
use Test::Nginx::HTTP3;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/http http_v3 cryptx/)
	->has_daemon('openssl')->plan(2)
	->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    ssl_certificate localhost.crt;
    ssl_certificate_key localhost.key;

    server {
        listen       127.0.0.1:%%PORT_8980_UDP%% quic;
        server_name  localhost;

        error_log default.log info;
    }

    server {
        listen       127.0.0.1:%%PORT_8980_UDP%% quic;
        server_name  virtual;

        error_log virtual.log info;

        location / {
            return 204;
        }
    }
}

EOF

$t->write_file('openssl.conf', <<EOF);
[ req ]
default_bits = 2048
encrypt_key = no
distinguished_name = req_distinguished_name
[ req_distinguished_name ]
EOF

my $d = $t->testdir();

foreach my $name ('localhost') {
	system('openssl req -x509 -new '
		. "-config $d/openssl.conf -subj /CN=$name/ "
		. "-out $d/$name.crt -keyout $d/$name.key "
		. ">>$d/openssl.out 2>&1") == 0
		or die "Can't create certificate for $name: $!\n";
}

$t->run();

###############################################################################

my $s = Test::Nginx::HTTP3->new(8980, sni => 'virtual');

# request stream closed without a request

$s->raw_write($s->build_stream(''));

# a request on the same connection, to wait for the stream above

my $sid = $s->new_stream({ host => 'virtual' });
$s->read(all => [{ sid => $sid, fin => 1 }]);

TODO: {
local $TODO = 'not yet';

like($t->read_file('virtual.log'), qr/waiting for request/,
	'virtual server log');
unlike($t->read_file('default.log'), qr/waiting for request/,
	'default server log');

}

###############################################################################
