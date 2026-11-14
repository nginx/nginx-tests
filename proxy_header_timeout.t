#!/usr/bin/perl

# (C) Nginx, Inc.

# Tests for the proxy_header_timeout directive.

###############################################################################

use warnings;
use strict;

use Test::More;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/http proxy/);

plan(skip_all => 'not yet') unless $t->has_version('1.31.7');

$t->write_file_expand('nginx.conf', <<'EOF')->plan(6);

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    log_format addr '$upstream_addr';

    upstream u {
        server 127.0.0.1:8081 max_fails=0;
        server 127.0.0.1:8081 max_fails=0;
    }

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        proxy_read_timeout 5s;

        location / {
            proxy_pass http://127.0.0.1:8081/header;
            proxy_header_timeout 500ms;
        }

        location /read {
            proxy_pass http://127.0.0.1:8081/header;
            proxy_read_timeout 500ms;
            proxy_header_timeout 3s;
        }

        location /default {
            proxy_pass http://127.0.0.1:8081/header;
            proxy_read_timeout 500ms;
        }

        location /body {
            proxy_pass http://127.0.0.1:8081/body;
            proxy_header_timeout 500ms;
        }

        location /send {
            proxy_pass http://127.0.0.1:8081/echo;
            proxy_request_buffering off;
            proxy_header_timeout 700ms;
        }

        location /next {
            proxy_pass http://u/header;
            proxy_next_upstream timeout;
            proxy_header_timeout 400ms;
            access_log %%TESTDIR%%/next.log addr;
        }
    }
}

EOF

my $p = port(8081);

$t->run_daemon(\&http_daemon);
$t->run()->waitforsocket('127.0.0.1:' . $p);

###############################################################################

like(http_get('/read'), qr/SEE-THIS/, 'read timeout not used in header phase');
like(http_get('/body'), qr/SEE-THIS/, 'body not affected');

like(http_post('/send'), qr/504 /, 'request send included');
like(http_get('/'), qr/504 /, 'header timeout');
like(http_get('/default'), qr/504 /, 'read timeout used if not set');

http_get('/next');

$t->stop();

is($t->read_file('next.log'), "127.0.0.1:$p, 127.0.0.1:$p\n", 'next upstream');

###############################################################################

sub http_post {
	my ($uri) = @_;

	my $s = http(<<EOF, start => 1);
POST $uri HTTP/1.0
Host: localhost
Content-Length: 10

EOF

	select undef, undef, undef, 1.2;
	return http('0123456789', socket => $s);
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
		my $uri = '';

		while (<$client>) {
			$headers .= $_;
			last if (/^\x0d?\x0a?$/);
		}

		$uri = $1 if $headers =~ /^\S+\s+([^ ]+)\s+HTTP/i;

		if ($uri eq '/header') {
			select undef, undef, undef, 1.1;

			print $client <<EOF;
HTTP/1.1 200 OK
Connection: close

SEE-THIS
EOF

		} elsif ($uri eq '/body') {

			print $client <<EOF;
HTTP/1.1 200 OK
Connection: close

EOF

			select undef, undef, undef, 1.1;
			print $client 'SEE-THIS';

		} elsif ($uri eq '/echo') {
			my $len = 0;
			$len = $1 if $headers =~ /Content-Length:\s*(\d+)/i;
			read($client, my $body, $len) if $len;

			print $client <<EOF;
HTTP/1.1 200 OK
Connection: close

SEE-THIS
EOF
		}

		close $client;
	}
}

###############################################################################
