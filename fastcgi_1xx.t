#!/usr/bin/perl

# (C) Maxim Dounin

# Test for fastcgi backend with 1xx responses.

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

my $t = Test::Nginx->new()->has(qw/http fastcgi/)->plan(100)
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
$t->run()->waitforsocket('127.0.0.1:' . port(8081));

###############################################################################

for (my $i = 100; $i < 200; ++$i) {
        my $rsp = http(<<EOF);
GET /$i HTTP/1.1\r
Host: localhost\r
Upgrade: foo\r
Connection: close, Upgrade\r
\r
EOF
        like($rsp, qr|\AHTTP/1.1 502 Bad Gateway\r\n|aa);
}

###############################################################################

sub fastcgi_daemon {
	my $socket = FCGI::OpenSocket('127.0.0.1:' . port(8081), 5);
	my $request = FCGI::Request(\*STDIN, \*STDOUT, \*STDERR, \%ENV,
		$socket);

	my $count;
	while( $request->Accept() >= 0 ) {
		$count++;

		my $request_uri = $ENV{REQUEST_URI};
                if ($request_uri !~ qr|\A/([1-5][0-9]{2})\z|aa) {
                        print <<EOF;
Status: 404 Not Found

EOF
                        next;
                }

		print <<EOF;
Status: $1 Some Status
Upgrade: foo
Connection: upgrade

EOF
	}

	FCGI::CloseSocket($socket);
}

###############################################################################
