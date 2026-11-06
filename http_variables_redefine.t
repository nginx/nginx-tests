#!/usr/bin/perl

# (C) Elijah Zupancic
# (C) F5, Inc.

# Tests for redefinition of variables: variables with set handlers,
# named captures and auth_request_set.

###############################################################################

use warnings;
use strict;

use Test::More;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;
use Test::Nginx::Stream qw/ stream /;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()
	->has(qw/http rewrite map geo split_clients auth_request proxy/)
	->has(qw/stream stream_map stream_return/)
	->plan(14)->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    map $uri $foo {
        default  map;
    }

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        location /foo {
            return 200 "foo:$foo http_foo:$http_foo http_bar:$http_bar";
        }

        location ~ ^/re/(?<foo>.*) {
            return 200 "foo:$foo";
        }

        location ~ ^/re2/(?<http_foo>.*) {
            return 200 "http_foo:$http_foo";
        }

        location = /auth.html {
            auth_request /auth_ok;
            auth_request_set $http_bar "set";
            add_header X-Bar $http_bar;
        }

        location = /auth_ok {
            return 204;
        }

        location /set {
            set $limit_rate 100k;
            set $args "a=b";
            return 200 "limit_rate:$limit_rate args:$args";
        }
    }
}

stream {
    %%TEST_GLOBALS_STREAM%%

    map $server_port $sfoo {
        default  map;
    }

    server {
        listen  127.0.0.1:8081;
        return  "sfoo:$sfoo";
    }

    server {
        listen      127.0.0.1:8082;
        server_name ~^(?<sfoo>.+)$;
        return      "never";
    }

    server {
        listen  127.0.0.1:8083 proxy_protocol;
        return  "alpn:$proxy_protocol_tlv_alpn";
    }

    server {
        listen      127.0.0.1:8084;
        server_name ~^(?<proxy_protocol_tlv_alpn>.+)$;
        return      "never";
    }
}

EOF

$t->write_file('auth.html', '');
$t->run();

my $testdir = $t->testdir();
my $globals = $t->test_globals();
my $globals_http = $t->test_globals_http();

###############################################################################

# legitimate writers of variables with set handlers

like(http_get('/set?x=y'), qr/limit_rate:102400 args:a=b/,
	'set with set handler');

# named captures and auth_request_set do not hide other variables

like(http_get('/re/capture'), qr/foo:capture/, 'named capture');
like(http_get('/re2/capture'), qr/http_foo:capture/,
	'named capture prefix variable');
like(http_get('/auth.html'), qr/X-Bar: set/, 'auth_request_set');

TODO: {
local $TODO = 'not yet' unless $t->has_version('1.31.9');

like(http_get('/foo'), qr/foo:map /, 'map not hidden by capture');
like(http_foo_bar('/foo'), qr/http_foo:hfoo /,
	'prefix variable not hidden by capture');
like(http_foo_bar('/foo'), qr/http_bar:hbar$/,
	'prefix variable not hidden by auth_request_set');
like(stream('127.0.0.1:' . port(8081))->read(), qr/sfoo:map/,
	'stream map not hidden by capture');
like(stream('127.0.0.1:' . port(8083))->io(pp2_alpn('ALPN1')),
	qr/alpn:ALPN1/, 'stream prefix variable not hidden by capture');

# map, geo and split_clients cannot redefine variables with set handlers

like(check_conf("map \$uri \$limit_rate { default 1; }"),
	qr/duplicate "limit_rate" variable/, 'map limit_rate rejected');
like(check_conf("geo \$args { default a; }"),
	qr/duplicate "args" variable/, 'geo args rejected');
like(check_conf("split_clients \$uri \$limit_rate { 50% 1; * 2; }"),
	qr/duplicate "limit_rate" variable/,
	'split_clients limit_rate rejected');

SKIP: {
skip 'no json', 1 unless $t->has_module('json');

like(check_conf("json_set \$limit_rate \$arg_json a;"),
	qr/duplicate "limit_rate" variable/, 'json_set limit_rate rejected');

}

}

unlike(check_conf("map \$uri \$x { default 1; }"), qr/emerg/,
	'map new variable');

###############################################################################

sub http_foo_bar {
	my ($uri) = @_;
	return http(<<EOF);
GET $uri HTTP/1.0
Host: localhost
Foo: hfoo
Bar: hbar

EOF
}

sub pp2_alpn {
	my ($alpn) = @_;

	# PROXY protocol v2 header with the ALPN TLV

	my $tlv = pack("CnA*", 0x1, length($alpn), $alpn);
	my $addrs = pack('N2n2', 0xc0000201, 0xc0000202, 123, 5678);

	return pack("N3", 0x0D0A0D0A, 0x000D0A51, 0x5549540A)
		. pack('C2n', 0x21, 0x11, length($addrs) + length($tlv))
		. $addrs . $tlv;
}

sub check_conf {
	my ($snippet) = @_;

	# no server block: "nginx -t" opens listening sockets
	my $conf = $globals . "\n"
		. "daemon off;\n"
		. "events {}\n"
		. "http {\n"
		. $globals_http . "\n"
		. "    $snippet\n"
		. "}\n";

	my $file = "$testdir/check.conf";
	open my $fh, '>', $file or die "can't open $file: $!";
	print $fh $conf;
	close $fh;

	# a dedicated log keeps errors out of the error.log checked on teardown
	my $bin = $Test::Nginx::NGINX;
	return `$bin -t -p $testdir/ -c check.conf -e check_error.log 2>&1`;
}

###############################################################################
