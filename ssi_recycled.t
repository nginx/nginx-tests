#!/usr/bin/perl

# (C) Nginx, Inc.

# Tests for ssi_ignore_recycled_buffers with small proxy buffers.

###############################################################################

use warnings;
use strict;

use Test::More;

use IO::Socket::INET;
use Socket qw/ CRLF /;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/http proxy ssi/)->plan(2);

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
            ssi on;
            ssi_ignore_recycled_buffers on;

            proxy_pass http://127.0.0.1:8081;

            proxy_buffer_size 128;
            proxy_buffers 2 128;
            proxy_busy_buffers_size 128;
            proxy_max_temp_file_size 0;
            proxy_read_timeout 1s;
        }

        location /off {
            ssi on;
            ssi_ignore_recycled_buffers off;

            proxy_pass http://127.0.0.1:8081;

            proxy_buffer_size 128;
            proxy_buffers 2 128;
            proxy_busy_buffers_size 128;
            proxy_max_temp_file_size 0;
            proxy_read_timeout 1s;
        }
    }
}

EOF

$t->run_daemon(\&http_daemon);
$t->run()->waitforsocket('127.0.0.1:' . port(8081));

###############################################################################

like(http_get('/off'), qr/^x{2048}$/m, 'recycled buffers');

TODO: {
local $TODO = 'not yet' unless $t->has_version('1.31.10');

like(http_get('/'), qr/^x{2048}$/m, 'ignore recycled buffers');

}

###############################################################################

sub http_daemon {
	my $server = IO::Socket::INET->new(
		Proto => 'tcp',
		LocalAddr => '127.0.0.1:' . port(8081),
		Listen => 5,
		Reuse => 1
	)
		or die "Can't create listening socket: $!\n";

	local $SIG{PIPE} = 'IGNORE';

	while (my $client = $server->accept()) {
		$client->autoflush(1);

		while (<$client>) {
			last if (/^\x0d?\x0a?$/);
		}

		print $client
			"HTTP/1.1 200 OK" . CRLF .
			"Content-Type: text/html" . CRLF .
			"Content-Length: 2048" . CRLF .
			"Connection: close" . CRLF .
			CRLF;

		for (1 .. 32) {
			print $client 'x' x 64;
			select undef, undef, undef, 0.02;
		}
	}
}

###############################################################################
