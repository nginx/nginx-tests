#!/usr/bin/perl

# (C) Zhidao HONG
# (C) Nginx, Inc.

# Tests for HTTP/2 proxy backend with cache support.

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

my $t = Test::Nginx->new()->has(qw/http rewrite http_v2 proxy cache/)
	->has(qw/upstream_keepalive/)->plan(3);

$t->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    proxy_cache_path   %%TESTDIR%%/cache  levels=1:2
                       keys_zone=NAME:1m;

    server {
        listen       127.0.0.1:8080 http2;
        server_name  localhost;

        location / {
            proxy_pass http://127.0.0.1:8081;
            proxy_http_version 2;
            proxy_request_buffering off;
            proxy_set_header TE "trailers";
            proxy_pass_trailers on;

            proxy_cache   NAME;
            proxy_cache_valid   200 302  2s;

            add_header X-Cache-Status $upstream_cache_status;
        }
    }
}

EOF

# suppress deprecation warning

open OLDERR, ">&", \*STDERR; close STDERR;
$t->run();
open STDERR, ">&", \*OLDERR;

###############################################################################

my $p = port(8081);
my $f = proxy_http2();

# Test basic caching functionality - first request should be MISS

my $frames = $f->{http_start}('/');
my ($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
ok($frame, 'cache test - got first response');

$f->{data}('Hello');
$frames = $f->{http_end}();
($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
like($frame->{headers}{'x-cache-status'}, qr/MISS/, 'cache test - MISS on first request');

# Second request - should be HIT from cache

$frames = $f->{request}('/');
($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
like($frame->{headers}{'x-cache-status'}, qr/HIT/, 'cache test - HIT on second request');

###############################################################################

sub proxy_http2 {
	my ($server, $client, $f, $s, $c, $sid, $csid);
	my $n = 0;

	$server = IO::Socket::INET->new(
		Proto => 'tcp',
		LocalHost => '127.0.0.1',
		LocalPort => $p,
		Listen => 5,
		Reuse => 1
	)
		or die "Can't create listening socket: $!\n";

	$f->{http_start} = sub {
		my ($uri, %extra) = @_;
		my $body_more = 1;
		my $meth = $extra{method} || 'GET';
		$s = Test::Nginx::HTTP2->new() if !defined $s;
		$csid = $s->new_stream({ body_more => $body_more, headers => [
			{ name => ':method', value => $meth, mode => !!$meth },
			{ name => ':scheme', value => 'http', mode => 0 },
			{ name => ':path', value => $uri, },
			{ name => ':authority', value => 'localhost' },
			{ name => 'content-type', value => 'text/plain' },
			{ name => 'te', value => 'trailers', mode => 2 }]});

		if (IO::Select->new($server)->can_read(5)) {
			$client = $server->accept();
		} else {
			log_in("timeout");
			return undef;
		}

		log2c("(new connection $client)");
		$n++;

		$client->sysread(my $buf, 24) == 24 or return; # preface

		$c = Test::Nginx::HTTP2->new(1, socket => $client,
			pure => 1, preface => "") or return;

		my $frames = $c->read(all => [{ fin => 4 }]);

		$c->h2_settings(0);
		$c->h2_settings(1);

		my ($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
		$sid = $frame->{sid};
		return $frames;
	};
	$f->{data} = sub {
		my ($body, %extra) = @_;
		$s->h2_body($body, { %extra });
		return $c->read(all => [{ sid => $sid,
			length => length($body) }]);
	};
	$f->{http_end} = sub {
		my (%extra) = @_;

		my $h = [
			{ name => ':status', value => '200',
				mode => $extra{mode} || 0 },
			{ name => 'content-type', value => 'text/plain',
				mode => $extra{mode} || 1, huff => 1 },
			{ name => 'x-connection', value => $n,
				mode => 2, huff => 1 }];
		push @$h, { name => 'content-length', value => $extra{cl} }
			if $extra{cl};
		$c->new_stream({ body_more => 1, headers => $h, %extra }, $sid);

		$c->h2_body('Hello world', { body_more => 1,
			body_padding => $extra{body_padding} });
		$c->new_stream({ headers => [
			{ name => 'x-status', value => '0',
				mode => 2, huff => 1 },
			{ name => 'x-message', value => '',
				mode => 2, huff => 1 },
		]}, $sid);

		return $s->read(all => [{ fin => 1 }]);
	};
	$f->{request} = sub {
		my ($uri) = @_;
		$s = Test::Nginx::HTTP2->new() if !defined $s;
		my $sid = $s->new_stream({ path => $uri });
		return $s->read(all => [{ fin => 1 }]);
	};
	return $f;
}

sub log2i { Test::Nginx::log_core('|| <<', @_); }
sub log2o { Test::Nginx::log_core('|| >>', @_); }
sub log2c { Test::Nginx::log_core('||', @_); }

###############################################################################
