#!/usr/bin/perl

# (C) Andrew Clayton
# (C) Nginx, Inc.

# Tests for stream proxy_bind_device directive.

###############################################################################

use warnings;
use strict;

use Test::More;

use IO::Socket::INET;
use Socket qw/ SOL_SOCKET /;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $lo = $^O eq 'darwin' ? 'lo0' : 'lo';

# before Linux 5.7, SO_BINDTODEVICE requires CAP_NET_RAW

plan(skip_all => 'SO_BINDTODEVICE not permitted') unless eval {
	my $s = IO::Socket::INET->new(Proto => 'tcp');
	setsockopt($s, SOL_SOCKET, Socket::SO_BINDTODEVICE(), $lo);
};

my $t = Test::Nginx->new()->has(qw/http proxy stream stream_map/);

(my $conf = <<'EOF') =~ s/%%LO%%/$lo/g;

%%TEST_GLOBALS%%

daemon off;

events {
}

stream {
    %%TEST_GLOBALS_STREAM%%

    map $protocol $lo {
        default  %%LO%%;
    }

    map $protocol $nodev {
        default  nodev;
    }

    map $protocol $long {
        default  abcdefghijklmnop;
    }

    map $protocol $empty {
        default  "";
    }

    proxy_bind_device  nodev;

    server {
        listen             127.0.0.1:8081;
        proxy_pass         127.0.0.1:8090;
    }

    server {
        listen             127.0.0.1:8082;
        proxy_bind_device  %%LO%%;
        proxy_pass         127.0.0.1:8090;
    }

    server {
        listen             127.0.0.1:8083;
        proxy_bind_device  off;
        proxy_pass         127.0.0.1:8090;
    }

    server {
        listen             127.0.0.1:8084;
        proxy_bind_device  $lo;
        proxy_pass         127.0.0.1:8090;
    }

    server {
        listen             127.0.0.1:8085;
        proxy_bind_device  $empty;
        proxy_pass         127.0.0.1:8090;
    }

    server {
        listen             127.0.0.1:8086;
        proxy_bind_device  $nodev;
        proxy_pass         127.0.0.1:8090;
    }

    server {
        listen             127.0.0.1:8087;
        proxy_bind_device  $long;
        proxy_pass         127.0.0.1:8090;
    }

    server {
        listen             127.0.0.1:8088;
        proxy_bind_device  %%LO%%;
        proxy_bind         127.0.0.1;
        proxy_pass         127.0.0.1:8090;
    }
}

http {
    %%TEST_GLOBALS_HTTP%%

    server {
        listen          127.0.0.1:8080;
        server_name     localhost;

        location /inherit { proxy_pass http://127.0.0.1:8081/; }
        location /lo      { proxy_pass http://127.0.0.1:8082/; }
        location /off     { proxy_pass http://127.0.0.1:8083/; }
        location /var     { proxy_pass http://127.0.0.1:8084/; }
        location /empty   { proxy_pass http://127.0.0.1:8085/; }
        location /nodev   { proxy_pass http://127.0.0.1:8086/; }
        location /long    { proxy_pass http://127.0.0.1:8087/; }
        location /bind    { proxy_pass http://127.0.0.1:8088/; }
    }

    server {
        listen          127.0.0.1:8090;
        server_name     localhost;
    }
}

EOF

$t->write_file_expand('nginx.conf', $conf);
$t->write_file('index.html', '');
$t->try_run('no proxy_bind_device')->plan(13);

###############################################################################

like(http_get('/inherit'), qr/ 502 /, 'inherit');
like(http_get('/lo'), qr/ 200 /, 'lo');
like(http_get('/off'), qr/ 200 /, 'off');
like(http_get('/var'), qr/ 200 /, 'var');
like(http_get('/empty'), qr/ 200 /, 'var empty');
like(http_get('/nodev'), qr/ 502 /, 'var nodev');
like(http_get('/long'), qr/ 502 /, 'var too long');
like(http_get('/bind'), qr/ 200 /, 'with proxy_bind');

$t->stop();

like($t->read_file('error.log'),
	qr/setsockopt\(SO_BINDTODEVICE, nodev\) failed/, 'log nodev');
like($t->read_file('error.log'),
	qr/device name "abcdefghijklmnop" too long/, 'log too long');

# configuration errors

like(check_conf($t, 'proxy_bind_device lo; proxy_bind_device lo;'),
	qr/"proxy_bind_device" directive is duplicate/, 'conf duplicate');
like(check_conf($t, 'proxy_bind_device abcdefghijklmnop;'),
	qr/invalid device name "abcdefghijklmnop"/, 'conf too long');
like(check_conf($t, 'proxy_bind_device ${foo;'),
	qr/the closing bracket in "foo" variable is missing/, 'conf bad variable');

###############################################################################

sub check_conf {
	my ($t, $directive) = @_;

	my $d = $t->testdir();

	# no server block: "nginx -t" would open listening sockets

	$t->write_file('invalid.conf', $t->test_globals() . "\n"
		. "events {}\n"
		. "stream {\n"
		. $t->test_globals_stream() . "\n"
		. "    " . $directive . "\n"
		. "}\n");

	# a dedicated log keeps errors out of the error.log checked on teardown

	return `$Test::Nginx::NGINX -t -p $d/ -c invalid.conf -e invalid.log 2>&1`;
}

###############################################################################
