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

my $t = Test::Nginx->new()->has(qw/http proxy slice/)->plan(4);

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

TODO: {
local $TODO = 'not yet' unless $t->has_version('1.31.10');

unlike(http_get('/short'), qr/C{10}/, 'short slice');
unlike(http_get('/long'), qr/X{5}/, 'long slice');
unlike(http_get('/grow'), qr/C{10}/, 'complete length changed');

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

		if ($uri eq '/short' && $start == 10) {
			$body = 'B' x 5;

		} elsif ($uri eq '/long' && $start == 10) {
			$body = 'B' x 10 . 'X' x 5;

		} elsif ($uri eq '/grow' && $start == 0) {
			$total = 25;
		}

		print $client
			"HTTP/1.1 206 Partial Content" . CRLF .
			"Content-Range: bytes $start-$end/$total" . CRLF .
			"Content-Length: " . length($body) . CRLF .
			"Connection: close" . CRLF .
			CRLF .
			$body;
	}
}

###############################################################################
