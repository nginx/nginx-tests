#!/usr/bin/perl

# (C) Nginx, Inc.

# Tests for stream $server_name variable with virtual servers.

###############################################################################

use warnings;
use strict;

use Test::More;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;
use Test::Nginx::Stream qw/ stream /;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()
	->has(qw/stream stream_ssl stream_map stream_limit_conn stream_return/)
	->has(qw/socket_ssl_sni/)->has_daemon('openssl')->plan(4)
	->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

stream {
    %%TEST_GLOBALS_STREAM%%

    map $server_name $backend {
        default      127.0.0.1:8091;
        public.test  127.0.0.1:8092;
    }

    limit_conn_zone $server_name zone=by_name:1m;

    ssl_certificate_key localhost.key;
    ssl_certificate localhost.crt;

    server {
        listen       127.0.0.1:8080 ssl;
        server_name  admin.test;

        # evaluates $server_name before the server is selected

        limit_conn   by_name 10;

        proxy_pass   $backend;
    }

    server {
        listen       127.0.0.1:8080 ssl;
        server_name  public.test;

        proxy_pass   $backend;
    }

    server {
        listen       127.0.0.1:8081 ssl;
        server_name  admin.test;

        proxy_pass   $backend;
    }

    server {
        listen       127.0.0.1:8081 ssl;
        server_name  public.test;

        proxy_pass   $backend;
    }

    server {
        listen       127.0.0.1:8091;
        return       ADMIN;
    }

    server {
        listen       127.0.0.1:8092;
        return       PUBLIC;
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

is(get('public.test', 8081), 'PUBLIC', 'server name');
is(get('admin.test', 8081), 'ADMIN', 'server name - default server');

is(get('admin.test', 8080), 'ADMIN', 'server name evaluated early');

TODO: {
local $TODO = 'not yet' unless $t->has_version('1.31.10');

is(get('public.test', 8080), 'PUBLIC', 'server name evaluated early - sni');

}

###############################################################################

sub get {
	my ($host, $port) = @_;

	my $s = stream(
		PeerAddr => '127.0.0.1:' . port($port),
		SSL => 1,
		SSL_hostname => $host
	);

	return $s->read();
}

###############################################################################
