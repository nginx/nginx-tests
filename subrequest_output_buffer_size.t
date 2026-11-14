#!/usr/bin/perl

# (C) Sergey Kandaurov
# (C) Nginx, Inc.

# Tests for subrequest_output_buffer_size directive.

###############################################################################

use warnings;
use strict;

use Test::More;

use IO::Socket;
use Socket qw/ CRLF /;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/http proxy ssi/)->plan(5)
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

        location / {
            proxy_pass http://127.0.0.1:8081;
            subrequest_output_buffer_size 42;
        }

        location /longok {
            proxy_pass http://127.0.0.1:8081/long;
        }

        location /huge {
            proxy_pass http://127.0.0.1:8082;
            subrequest_output_buffer_size 42;
        }

        location /ssi {
            ssi on;
        }
    }

    server {
        listen       127.0.0.1:8081;
        server_name  localhost;

        location / { }
    }
}

EOF

$t->write_file('ssi.html',
	'<!--#include virtual="/$arg_c" set="x" -->' .
	'set: <!--#echo var="x" -->');

$t->write_file('length', 'TEST-OK-IF-YOU-SEE-THIS');
$t->write_file('long', 'x' x 400);
$t->write_file('empty', '');

$t->run_daemon(\&http_daemon);
$t->run()->waitforsocket('127.0.0.1:' . port(8082));

###############################################################################

my ($r, $n);

like(http_get('/ssi.html?c=length'), qr/SEE-THIS/, 'request');
like(http_get('/ssi.html?c=empty'), qr/set: $/, 'empty');
unlike(http_get('/ssi.html?c=long'), qr/200 OK/, 'long');
like(http_get('/ssi.html?c=longok'), qr/x{400}/, 'long ok');

# Content-Length larger than 2^32 should be rejected on all platforms,
# in particular, it should not be truncated on 32-bit platforms

TODO: {
local $TODO = 'not yet' unless $t->has_version('1.31.9');

unlike(http_get('/ssi.html?c=huge'), qr/200 OK/, 'huge content length');

}

###############################################################################

sub http_daemon {
	my $server = IO::Socket::INET->new(
		Proto => 'tcp',
		LocalAddr => '127.0.0.1:' . port(8082),
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
			"Content-Length: 4294967338" . CRLF .
			"Connection: close" . CRLF .
			CRLF .
			"TEST";

		close $client;
	}
}

###############################################################################
