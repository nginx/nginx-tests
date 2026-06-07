#!/usr/bin/perl

# (C) Maxim Dounin
# (C) Demi Marie Obenour

# Test for upstream handling of 2xx responses to CONNECT requests.

###############################################################################

use warnings;
use strict;
use feature 'signatures';

use Test::More;
use Socket qw/ CRLF /;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;
eval { require FCGI; };
plan(skip_all => 'FCGI not installed') if $@;

my $t = Test::Nginx->new()->has(qw/http fastcgi/)->plan(1)
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
            if ($http_cookie != $http_cookie) {
                # never reached
                tunnel_pass;
            }
            fastcgi_pass 127.0.0.1:8081;
            fastcgi_param REQUEST_URI $request_uri;
            fastcgi_param CONTENT_LENGTH $content_length;
            fastcgi_param REQUEST_METHOD $request_method;
            fastcgi_param HTTPS $https if_not_empty;
            fastcgi_param QUERY_STRING $query_string;
        }
    }
}

EOF

$t->run_daemon(\&fastcgi_daemon);
$t->try_run(qw/tunnel/)->waitforsocket('127.0.0.1:' . port(8081));

###############################################################################


like(http(<<EOF), qr|\AHTTP/1.1 500 Internal Server Error\r\n|aa);
CONNECT 255.255.255.255:1 HTTP/1.1\r
Host: localhost\r
Connection: close\r
\r
EOF

###############################################################################

sub fastcgi_daemon {
	my $socket = FCGI::OpenSocket('127.0.0.1:' . port(8081), 5);
	my $request = FCGI::Request(\*STDIN, \*STDOUT, \*STDERR, \%ENV,
		$socket);

	my $count;
	while( $request->Accept() >= 0 ) {
		$count++;

		my $request_uri = $ENV{REQUEST_URI};
		print <<EOF;
Status: 200 OK

EOF
	}

	FCGI::CloseSocket($socket);
}

###############################################################################

