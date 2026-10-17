#!/usr/bin/perl

# (C) Vadim Zhestikov
# (C) Nginx, Inc.

# Tests for http proxy cache with proxy_next_upstream.

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

my $t = Test::Nginx->new()->has(qw/http proxy cache/)->plan(6);

$t->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    proxy_cache_path   %%TESTDIR%%/cache  keys_zone=NAME:1m;

    upstream u {
        server 127.0.0.1:8081 max_fails=0;
        server 127.0.0.1:8082 backup;
    }

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        location / {
            proxy_pass http://u;
            proxy_next_upstream invalid_header http_500;

            proxy_cache NAME;
            proxy_cache_valid 200 10m;

            add_header X-Cache-Status $upstream_cache_status;
        }
    }

    server {
        listen       127.0.0.1:8082;
        server_name  localhost;

        location / {
            return 200 "SEE-THIS";
        }
    }
}

EOF

$t->run_daemon(\&http_daemon);
$t->run()->waitforsocket('127.0.0.1:' . port(8081));

###############################################################################

# headers of a response, which was passed to the next upstream,
# do not affect caching of the next upstream response

like(http_get('/control'), qr/MISS.*SEE-THIS/s, 'control');
like(http_get('/control'), qr/HIT/, 'control cached');

TODO: {
local $TODO = 'not yet';

http_get('/set-cookie');
like(http_get('/set-cookie'), qr/HIT/, 'set-cookie');

http_get('/x-accel-expires');
like(http_get('/x-accel-expires'), qr/HIT/, 'x-accel-expires');

http_get('/vary');
like(http_get('/vary'), qr/HIT/, 'vary');

http_get('/error');
like(http_get('/error'), qr/HIT/, 'error');

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

	my %headers = (
		'/set-cookie' => 'Set-Cookie: foo=bar',
		'/x-accel-expires' => 'X-Accel-Expires: @1',
		'/vary' => 'Vary: *',
	);

	local $SIG{PIPE} = 'IGNORE';

	while (my $client = $server->accept()) {
		$client->autoflush(1);

		my $headers = '';
		my $uri = '';

		while (<$client>) {
			$headers .= $_;
			last if (/^\x0d?\x0a?$/);
		}

		$uri = $1 if $headers =~ /^\S+\s+([^ ]+)\s+HTTP/i;

		if ($uri eq '/error') {
			print $client
				'HTTP/1.1 500 Internal Server Error' . CRLF .
				'Set-Cookie: foo=bar' . CRLF .
				'Connection: close' . CRLF .
				'Content-Length: 3' . CRLF . CRLF .
				'BAD';

			close $client;
			next;
		}

		print $client
			'HTTP/1.1 200 OK' . CRLF .
			($headers{$uri} ? $headers{$uri} . CRLF : '') .
			'Invalid Header: foo' . CRLF .
			'Connection: close' . CRLF .
			'Content-Length: 3' . CRLF . CRLF .
			'BAD';

		close $client;
	}
}

###############################################################################
