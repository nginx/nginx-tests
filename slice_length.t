#!/usr/bin/perl

# (C) Nginx, Inc.

# Tests for slice filter, inconsistent slice responses.

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

my $t = Test::Nginx->new()->has(qw/http proxy slice/)->plan(6);

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
            slice 10;
            postpone_output 0;

            proxy_pass    http://127.0.0.1:8081;

            proxy_set_header   Range  $slice_range;
        }
    }
}

EOF

$t->run_daemon(\&http_daemon);
$t->run()->waitforsocket('127.0.0.1:' . port(8081));

###############################################################################

like(http_get('/exact'), qr/\x0d\x0a\x0d\x0aA{10}B{10}C{10}$/, 'exact slices');

# with postpone_output 0 the header and the slices before the invalid one
# reach the client, and the response is cut there; without Content-Length
# a short slice is known to be short only when its body ends

TODO: {
local $TODO = 'not yet' unless $t->has_version('1.31.10');

like(http_get('/short'), qr/\x0d\x0a\x0d\x0aA{10}$/, 'short slice');
like(http_get('/long'), qr/\x0d\x0a\x0d\x0aA{10}$/, 'long slice');
like(http_get('/short/nolen'), qr/\x0d\x0a\x0d\x0aA{10}B{5}$/,
	'short slice no length');
like(http_get('/long/nolen'), qr/\x0d\x0a\x0d\x0aA{10}$/,
	'long slice no length');
like(http_get('/grow'), qr/\x0d\x0a\x0d\x0aA{10}$/, 'complete length changed');

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

		my $headers = '';
		my $uri = '';

		while (<$client>) {
			$headers .= $_;
			last if (/^\x0d?\x0a?$/);
		}

		$uri = $1 if $headers =~ /^\S+\s+([^ ]+)\s+HTTP/i;

		my ($start, $end) = $headers =~ /^Range: bytes=(\d+)-(\d+)/mi;
		next unless defined $start;

		my $total = 30;
		my $body = substr('A' x 10 . 'B' x 10 . 'C' x 10, $start, 10);

		if ($uri =~ m!^/short! && $start == 10) {
			$body = 'B' x 5;

		} elsif ($uri =~ m!^/long! && $start == 10) {
			$body = 'B' x 10 . 'X' x 5;

		} elsif ($uri eq '/grow' && $start == 0) {
			$total = 25;
		}

		my $length = "Content-Length: " . length($body) . CRLF;
		$length = '' if $uri =~ /nolen/;

		print $client
			"HTTP/1.1 206 Partial Content" . CRLF .
			"Content-Range: bytes $start-$end/$total" . CRLF .
			$length .
			"Connection: close" . CRLF .
			CRLF .
			$body;
	}
}

###############################################################################
