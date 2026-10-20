#!/usr/bin/perl

# (C) Elijah Zupancic
# (C) F5, Inc.

# Tests for nginx request body reading, errors handled by a proxied
# error_page while the client keeps sending the body.

###############################################################################

use warnings;
use strict;

use Test::More;

use Socket qw/ CRLF /;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx qw/ :DEFAULT http_end /;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/http proxy/)->plan(2)
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

        client_header_buffer_size 1k;
        client_body_timeout 1s;

        location / {
            client_max_body_size 1k;
            error_page 413 = @error;
            proxy_pass http://127.0.0.1:8081;
        }

        location @error {
            proxy_pass http://127.0.0.1:8081;
            proxy_ignore_client_abort on;
            proxy_read_timeout 5s;
        }
    }
}

EOF

$t->run_daemon(\&http_daemon);
$t->run()->waitforsocket('127.0.0.1:' . port(8081));

###############################################################################

# once reading the request body fails with 413 and the error page is
# being proxied, further client data should be ignored; previously, it
# was passed to the body reading handler again, and the body timeout
# terminated the request before the error page was returned

TODO: {
local $TODO = 'not yet' unless $t->has_version('1.31.9');

# error returned from the body reading handler, after the request headers

my $s = http(
	'POST /async HTTP/1.1' . CRLF
	. 'Host: localhost' . CRLF
	. 'Transfer-Encoding: chunked' . CRLF . CRLF
	. '1' . CRLF . 'X' . CRLF,
	start => 1
);

select undef, undef, undef, 0.3;
$s->print('800' . CRLF);
select undef, undef, undef, 0.3;
$s->print('X' x 100);
select undef, undef, undef, 0.3;
$s->print('X' x 100);
select undef, undef, undef, 0.3;

like(http_end($s), qr/ 200 .*SEE-THIS/s, 'error page with more body');

# error returned while reading the body for the first time, with the
# offending chunk beyond the preread part of the body but already in
# the socket buffer

$s = http(
	'POST /sync HTTP/1.1' . CRLF
	. 'Host: localhost' . CRLF
	. 'Transfer-Encoding: chunked' . CRLF . CRLF
	. ('1' . CRLF . 'X' . CRLF) x 200
	. '800' . CRLF . 'X',
	start => 1
);

select undef, undef, undef, 0.3;
$s->print('X' x 100);
select undef, undef, undef, 0.3;
$s->print('X' x 100);
select undef, undef, undef, 0.3;

like(http_end($s), qr/ 200 .*SEE-THIS/s, 'error page with more body sync');

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

		# reply after the client body timeout would have expired

		select undef, undef, undef, 2;

		print $client
			"HTTP/1.1 200 OK" . CRLF .
			"Content-Length: 8" . CRLF .
			"Connection: close" . CRLF . CRLF .
			"SEE-THIS";

		close $client;
	}
}

###############################################################################
