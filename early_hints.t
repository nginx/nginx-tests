#!/usr/bin/perl

# (C) Eugene Grebenschikov

# Tests for early hints via HTTP.

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

my $t = Test::Nginx->new()->has(qw/http proxy/);

plan(skip_all => "not yet") unless $t->has_version('1.29.0');

$t->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    map $server_protocol $early_hints {
        "HTTP/1.1" 1;
        "HTTP/1.0" 1;
    }

    early_hints $early_hints;

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        proxy_read_timeout 2s;
        proxy_connect_timeout 2s;
        proxy_buffer_size 4k;

        location / {
            proxy_pass http://127.0.0.1:8081;
        }

        location ~* onoff {
            early_hints $arg_hints;
            proxy_pass http://127.0.0.1:8081;
        }
    }
}

EOF

$t->run_daemon(\&http_daemon)->waitforsocket('127.0.0.1:' . port(8081))
	or die 'No socket 127.0.0.1:' . port(8081) . ' open';

$t->run()->plan(7);

###############################################################################

my $s = http_get_11('/early-hints', start => 1);
like(<$s>, qr'HTTP/1.1 103 Early Hints', '103 - pass early hints');
like(<$s>, qr'Link: <https://example.com>; rel="preconnect"',
	'header - pass early hints');
<$s>;
like(eval {local $/; <$s>;}, qr'^HTTP/1.1 200 OK', '200 - pass early hints');
close $s;

like(http_get_11('/early-hints-onoff'), qr'^HTTP/1.1 200 OK',
	'200 - dont\'t pass early hints');

like(http_get('/early-hints'), qr'^HTTP/1.1 200 OK',
	'200 - dont\'t pass early hints, old client');

like(http_get_11('/'), qr'^HTTP/1.1 200 OK', '200 - no early hints');

like(http_get_11('/huge-early-hints'), qr'^HTTP/1.1 502 Bad Gateway',
	'200 - too big early hints');

###############################################################################

sub http_get_11 {
	my ($url, %extra) = @_;

	return http(<<"EOF", %extra);
GET $url HTTP/1.1
Host: localhost
Connection: close

EOF
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
		my $uri = '';

		while (<$client>) {
			$headers .= $_;
			last if (/^\x0d?\x0a?$/);
		}

		$uri = $1 if $headers =~ /^\S+\s+([^ ]+)\s+HTTP/i;

		if ($uri =~ /early/) {
			my $links  = 'Link: <https://example.com>; rel="preconnect"';
			$links .= $uri =~ /huge/ ? (CRLF . $links) x 100 : '';
			print $client <<"EOF";
HTTP/1.1 103 Early Hints
$links

EOF
			select undef, undef, undef, 0.2;
		}

		print $client <<'EOF';
HTTP/1.1 200 OK
Connection: close

EOF

		close $client;
	}
}

###############################################################################
