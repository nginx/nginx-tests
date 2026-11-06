#!/usr/bin/perl

# (C) Nginx, Inc.

# Tests for http proxy cache with a large upstream header block.

###############################################################################

use warnings;
use strict;

use Test::More;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use Socket qw/ CRLF /;

use lib 'lib';
use Test::Nginx;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/http proxy cache/)->plan(4)
	->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    proxy_cache_path %%TESTDIR%%/cache keys_zone=NAME:1m;

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        location / {
            proxy_pass http://127.0.0.1:8081;
            proxy_cache NAME;
            proxy_buffer_size 128k;
            proxy_buffers 4 128k;
            proxy_hide_header X-Pad;
            add_header X-Cache-Status $upstream_cache_status;
        }
    }
}

EOF

$t->run_daemon(\&http_daemon);
$t->run()->waitforsocket('127.0.0.1:' . port(8081));

###############################################################################

# a response with a header block of exactly 65536 bytes: the body offset
# stored in the cache file wraps around to the header offset, and a hit
# used to be sent as a response without headers, starting with the
# cached header block

like(http_get('/'), qr/X-Cache-Status: MISS.*\x0d\x0a\x0d\x0ahello$/s,
	'large header block');

TODO: {
local $TODO = 'not yet' unless $t->has_version('1.31.9');

unlike(http_get('/'), qr/X-Pad/, 'large header block - hidden header');
like(http_get('/'), qr/^HTTP\/1\.1 200 OK\x0d\x0a.*X-Cache-Status: MISS/s,
	'large header block - not cached');
unlike(http_get('/'), qr/X-Pad/, 'large header block - hidden header kept');

}

###############################################################################

sub http_daemon {
	my $server = IO::Socket::INET->new(
		Proto => 'tcp',
		LocalHost => '127.0.0.1:' . port(8081),
		Listen => 5,
		Reuse => 1
	)
		or die "Can't create listening socket: $!\n";

	local $SIG{PIPE} = 'IGNORE';

	while (my $client = $server->accept()) {
		$client->autoflush(1);

		my $headers = '';

		while (<$client>) {
			$headers .= $_;
			last if (/^\x0d?\x0a?$/);
		}

		next if $headers eq '';

		my $body = 'hello';
		my $head = "HTTP/1.1 200 OK" . CRLF
			. "Cache-Control: max-age=60" . CRLF
			. "Content-Length: " . length($body) . CRLF
			. "Connection: close" . CRLF
			. "X-Pad: ";

		# the whole header block is exactly 65536 bytes

		$head .= 'x' x (65536 - length($head) - 4) . CRLF . CRLF;

		print $client $head . $body;
		close $client;
	}
}

###############################################################################
