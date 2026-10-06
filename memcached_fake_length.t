#!/usr/bin/perl

# (C) Nginx, Inc.

# Test for memcached backend returning a length that overflows.

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

my $t = Test::Nginx->new()->has(qw/http rewrite memcached/)->plan(1)
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
            set $memcached_key $uri;
            memcached_pass 127.0.0.1:8081;
        }
    }
}

EOF

$t->run_daemon(\&memcached_fake_daemon);
$t->run();

$t->waitforsocket('127.0.0.1:' . port(8081))
	or die "Can't start fake memcached";

###############################################################################

# a length that overflows when the size of the trailer is added to it
# is rejected, and is not sent to the client as a content length

TODO: {
local $TODO = 'not yet';

like(http_get('/'), qr/502 Bad/, 'memcached invalid length');

}

###############################################################################

sub memcached_fake_daemon {
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
			last if (/\x0d\x0a$/);
		}

		print $client 'VALUE / 0 9223372036854775807' . CRLF;
		print $client 'SEE-THIS' . CRLF . 'END' . CRLF;

		close $client;
	}
}

###############################################################################
