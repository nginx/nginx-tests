#!/usr/bin/perl

# (C) Nginx, Inc.

# Tests for worker_shutdown_timeout directive with HTTP/3.

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

my $t = Test::Nginx->new()->has(qw/http http_v3 cryptx proxy/)
	->has_daemon('openssl')->plan(3);

$t->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;
worker_shutdown_timeout 100ms;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    ssl_certificate_key localhost.key;
    ssl_certificate localhost.crt;

    server {
        listen       127.0.0.1:%%PORT_8980_UDP%% quic;
        server_name  localhost;

        location / {
            proxy_pass http://127.0.0.1:%%PORT_8081%%;
            proxy_read_timeout 5s;
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

$t->run_daemon(\&http_silent_daemon);
$t->run()->waitforsocket('127.0.0.1:' . port(8081));

###############################################################################

# Start an HTTP/3 request that blocks waiting for upstream response
my $s = Test::Nginx::HTTP3->new();
ok(defined $s->new_stream(), 'HTTP/3 request started');

# Reload NGINX so old worker enters shutting down state
$t->reload();

# worker_shutdown_timeout (100ms) expires while request is in-flight.
# The connection must be terminated with CONNECTION_CLOSE "shutdown timeout"
# rather than hanging for proxy_read_timeout (5s).
my $frames = $s->read(all => [{ type => 'CONNECTION_CLOSE' }]);

my ($frame) = grep { $_->{type} eq 'CONNECTION_CLOSE' } @$frames;
ok($frame, 'shutdown timeout CONNECTION_CLOSE received');
is($frame ? $frame->{'phrase'} : '', 'shutdown timeout', 'shutdown timeout phrase');

###############################################################################

sub http_silent_daemon {
	my $server = IO::Socket::INET->new(
		Proto => 'tcp',
		LocalAddr => '127.0.0.1:' . port(8081),
		Listen => 5,
		Reuse => 1
	)
		or die "Can't create listening socket: $!\n";

	while (my $client = $server->accept()) {
		$client->autoflush(1);
		while (<$client>) { }
	}
}

###############################################################################
