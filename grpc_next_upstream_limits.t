#!/usr/bin/perl

# (C) Elijah Zupancic
# (C) F5, Inc.

# Tests for grpc backend, PING and SETTINGS frame limits with
# grpc_next_upstream.

###############################################################################

use warnings;
use strict;

use Test::More;

use IO::Select;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx qw/ :DEFAULT http_end /;
use Test::Nginx::HTTP2;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/http http_v2 grpc/)->plan(10)
	->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    upstream ping {
        server 127.0.0.1:8081;
        server 127.0.0.1:8082;
    }

    upstream settings {
        server 127.0.0.1:8083;
        server 127.0.0.1:8084;
    }

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        grpc_buffer_size 64k;
        grpc_next_upstream error timeout invalid_header;

        location /ping {
            grpc_pass ping;
        }

        location /settings {
            grpc_pass settings;
        }
    }
}

EOF

my @srv = map {
	IO::Socket::INET->new(
		Proto => 'tcp',
		LocalHost => '127.0.0.1',
		LocalPort => port($_),
		Listen => 5,
		Reuse => 1
	)
		or die "Can't create listening socket: $!\n";
} (8081, 8082, 8083, 8084);

$t->run();

###############################################################################

# the limits on PING and SETTINGS frames sent by an upstream are expected
# to apply per upstream connection; previously, they were not reset when
# switching to the next upstream server, so that a misbehaving server
# exhausted the limit for the next one

my ($s, $c, $frames, $sid, $frame);

# ping

$s = http_get('/ping', start => 1);

$c = accept_h2($srv[0]);
$frames = $c->read(all => [{ fin => 4 }]);
ok((grep { $_->{type} eq 'HEADERS' } @$frames), 'ping - request');

# more PING frames than allowed, in one write, so that they are
# processed before the first acknowledgement is sent

$c->raw_write(pack("x2C2x5a8", 8, 0x6, 'PING') x 1100);

TODO: {
local $TODO = 'not yet' unless $t->has_version('1.31.9');

$c = accept_h2($srv[1]);
$frames = $c->read(all => [{ fin => 4 }]);
ok((grep { $_->{type} eq 'HEADERS' } @$frames), 'ping - next upstream');
($sid) = map { $_->{sid} } grep { $_->{type} eq 'HEADERS' } @$frames;

$c->h2_ping('PING');
$frames = $c->read(all => [{ type => 'PING' }], wait => 2);
($frame) = grep { $_->{type} eq 'PING' } @$frames;
is($frame->{flags}, 1, 'ping - next upstream ack');

http_response($c, $sid);
like(http_end($s), qr/ 200 /, 'ping - response');

}

# settings

$s = http_get('/settings', start => 1);

$c = accept_h2($srv[2]);
$frames = $c->read(all => [{ fin => 4 }]);
ok((grep { $_->{type} eq 'HEADERS' } @$frames), 'settings - request');

$c->raw_write(pack("x2C2x5", 0, 0x4) x 1100);

TODO: {
local $TODO = 'not yet' unless $t->has_version('1.31.9');

$c = accept_h2($srv[3]);
$frames = $c->read(all => [{ fin => 4 }]);
ok((grep { $_->{type} eq 'HEADERS' } @$frames), 'settings - next upstream');
($sid) = map { $_->{sid} } grep { $_->{type} eq 'HEADERS' } @$frames;

$c->h2_settings(0);
$frames = $c->read(all => [{ type => 'SETTINGS' }], wait => 2);
($frame) = grep { $_->{type} eq 'SETTINGS' && $_->{flags} == 1 } @$frames;
ok($frame, 'settings - next upstream ack');

http_response($c, $sid);
like(http_end($s), qr/ 200 /, 'settings - response');

}

$t->stop();

my $log = $t->read_file('error.log');

TODO: {
local $TODO = 'not yet' unless $t->has_version('1.31.9');

is(() = $log =~ /upstream sent too many ping frames/g, 1,
	'ping - limit once');
is(() = $log =~ /upstream sent too many settings frames/g, 1,
	'settings - limit once');

}

###############################################################################

sub accept_h2 {
	my ($srv) = @_;

	IO::Select->new($srv)->can_read(5) or return;

	my $client = $srv->accept() or return;
	$client->sysread(my $buf, 24) == 24 or return;

	return Test::Nginx::HTTP2->new(1, socket => $client,
		pure => 1, preface => "");
}

sub http_response {
	my ($c, $sid) = @_;

	$c->new_stream({ body_more => 1, headers => [
		{ name => ':status', value => '200', mode => 0 },
		{ name => 'content-type', value => 'application/grpc',
			mode => 1 }]}, $sid);
	$c->h2_body('Hello world', { body_more => 1 });
	$c->new_stream({ headers => [
		{ name => 'grpc-status', value => '0', mode => 2 }]}, $sid);
}

###############################################################################
