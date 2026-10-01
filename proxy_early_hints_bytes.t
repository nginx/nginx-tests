#!/usr/bin/perl

# (C) Sepuri Sai Krishna

# Tests for $body_bytes_sent with HTTP 103 Early Hints.

###############################################################################

use warnings;
use strict;

use Test::More;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;
use Test::Nginx::HTTP2;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/http http_v2 proxy/);

$t->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    log_format bytes  '$uri $server_protocol $body_bytes_sent';

    access_log %%TESTDIR%%/bytes.log bytes;

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        http2 on;
        early_hints 1;

        location / {
            proxy_pass http://127.0.0.1:8081;
            proxy_http_version 1.1;

            location /off/ {
                proxy_pass http://127.0.0.1:8081/;
                early_hints 0;
            }
        }
    }
}

EOF

$t->try_run('no early_hints')->plan(4);

$t->run_daemon(\&http_daemon);
$t->waitforsocket('127.0.0.1:' . port(8081));

###############################################################################

# bytes of a 103 response are header bytes, and are not to be counted
# in $body_bytes_sent

like(get('/'), qr/103.*200 OK.*SEE-THIS/s, 'early hints');

get('/off/');

my $s = Test::Nginx::HTTP2->new();
$s->read(all => [{ sid => $s->new_stream(), fin => 1 }]);

$t->stop();

my $log = $t->read_file('bytes.log');

like($log, qr!^/ HTTP/1\.1 8$!m, 'body bytes sent');
like($log, qr!^/off/ HTTP/1\.1 8$!m, 'body bytes sent - no early hints');
like($log, qr!^/ HTTP/2\.0 8$!m, 'body bytes sent - http2');

###############################################################################

sub get {
	my ($uri) = @_;
	http(<<EOF);
GET $uri HTTP/1.1
Host: localhost
Connection: close

EOF
}

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

		print $client <<'EOF';
HTTP/1.1 103
Link: </style.css>; rel=preload; as=style

EOF

		print $client <<'EOF';
HTTP/1.1 200 OK
Content-Length: 8
Connection: close

EOF

		print $client 'SEE-THIS';
	}
}

###############################################################################
