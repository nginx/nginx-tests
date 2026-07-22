#!/usr/bin/perl

# (C) Andrew Clayton
# (C) Nginx, Inc.

# Tests for HTTP/2 RFC9218 Extensible Prioritization Scheme.

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

my $t = Test::Nginx->new()->has(qw/http http_v2/)->plan(13)
	->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    http2 on;

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        location /proxy/ {
            proxy_pass http://127.0.0.1:8081/;
        }

        location /proxy_partial/ {
            proxy_pass http://127.0.0.1:8081/partial/;
        }
    }

    server {
        listen       127.0.0.1:8081;
        server_name  localhost;

        location / {
            add_header Priority "u=0";
            return 200 "upstream response";
        }

        location /partial/ {
            # Only urgency, no incremental - tests RFC9218 Section 8
            add_header Priority "u=1";
            return 200 "partial priority";
        }
    }
}

EOF

$t->run();

$t->write_file('small.html', 'SEE-THIS');

###############################################################################

# RFC9218: SETTINGS_NO_RFC7540_PRIORITIES (0x9) should be sent

my $s = Test::Nginx::HTTP2->new(port(8080), pure => 1);
my $frames = $s->read(all => [
	{ type => 'WINDOW_UPDATE' },
	{ type => 'SETTINGS' }
]);
my ($settings) = grep { $_->{type} eq 'SETTINGS' } @$frames;

ok($settings->{9}, 'SETTINGS_NO_RFC7540_PRIORITIES sent');
is($settings->{9}, 1, 'SETTINGS_NO_RFC7540_PRIORITIES value');

# RFC9218: Priority header with urgency

$s = Test::Nginx::HTTP2->new();
my $sid = $s->new_stream({ headers => [
	{ name => ':method', value => 'GET', mode => 0 },
	{ name => ':scheme', value => 'http', mode => 0 },
	{ name => ':path', value => '/small.html', mode => 1 },
	{ name => ':authority', value => 'localhost', mode => 1 },
	{ name => 'priority', value => 'u=1', mode => 2 }]});
$frames = $s->read(all => [{ sid => $sid, fin => 1 }]);

my ($data) = grep { $_->{type} eq 'DATA' } @$frames;
is($data->{data}, 'SEE-THIS', 'priority header u=1');

# RFC9218: Priority header with urgency and incremental

$s = Test::Nginx::HTTP2->new();
$sid = $s->new_stream({ headers => [
	{ name => ':method', value => 'GET', mode => 0 },
	{ name => ':scheme', value => 'http', mode => 0 },
	{ name => ':path', value => '/small.html', mode => 1 },
	{ name => ':authority', value => 'localhost', mode => 1 },
	{ name => 'priority', value => 'u=3, i', mode => 2 }]});
$frames = $s->read(all => [{ sid => $sid, fin => 1 }]);

($data) = grep { $_->{type} eq 'DATA' } @$frames;
is($data->{data}, 'SEE-THIS', 'priority header u=3, i');

# RFC9218: Priority header with i=?0 (explicit non-incremental)

$s = Test::Nginx::HTTP2->new();
$sid = $s->new_stream({ headers => [
	{ name => ':method', value => 'GET', mode => 0 },
	{ name => ':scheme', value => 'http', mode => 0 },
	{ name => ':path', value => '/small.html', mode => 1 },
	{ name => ':authority', value => 'localhost', mode => 1 },
	{ name => 'priority', value => 'u=5, i=?0', mode => 2 }]});
$frames = $s->read(all => [{ sid => $sid, fin => 1 }]);

($data) = grep { $_->{type} eq 'DATA' } @$frames;
is($data->{data}, 'SEE-THIS', 'priority header u=5, i=?0');

# RFC9218: Malformed priority header uses defaults

$s = Test::Nginx::HTTP2->new();
$sid = $s->new_stream({ headers => [
	{ name => ':method', value => 'GET', mode => 0 },
	{ name => ':scheme', value => 'http', mode => 0 },
	{ name => ':path', value => '/small.html', mode => 1 },
	{ name => ':authority', value => 'localhost', mode => 1 },
	{ name => 'priority', value => 'invalid', mode => 2 }]});
$frames = $s->read(all => [{ sid => $sid, fin => 1 }]);

($data) = grep { $_->{type} eq 'DATA' } @$frames;
is($data->{data}, 'SEE-THIS', 'malformed priority header');

# RFC9218: PRIORITY_UPDATE on stream 0 - protocol error for non-stream-0

$s = Test::Nginx::HTTP2->new();
$sid = $s->new_stream({ path => '/small.html' });
$frames = $s->read(all => [{ sid => $sid, fin => 1 }]);

# Send PRIORITY_UPDATE on wrong stream (should be on stream 0)
h2_priority_update_bad_stream($s, $sid, 'u=1');

$frames = $s->read(all => [{ type => 'GOAWAY' }], wait => 0.5);
my ($goaway) = grep { $_->{type} eq 'GOAWAY' } @$frames;
is($goaway->{code}, 1, 'PRIORITY_UPDATE on non-zero stream - PROTOCOL_ERROR');

# RFC9218: PRIORITY_UPDATE for even stream ID - protocol error

$s = Test::Nginx::HTTP2->new();
h2_priority_update($s, 2, 'u=1');

$frames = $s->read(all => [{ type => 'GOAWAY' }], wait => 0.5);
($goaway) = grep { $_->{type} eq 'GOAWAY' } @$frames;
is($goaway->{code}, 1, 'PRIORITY_UPDATE for even stream - PROTOCOL_ERROR');

# RFC9218: PRIORITY_UPDATE for stream 0 - protocol error

$s = Test::Nginx::HTTP2->new();
h2_priority_update($s, 0, 'u=1');

$frames = $s->read(all => [{ type => 'GOAWAY' }], wait => 0.5);
($goaway) = grep { $_->{type} eq 'GOAWAY' } @$frames;
is($goaway->{code}, 1, 'PRIORITY_UPDATE for stream 0 - PROTOCOL_ERROR');

# RFC9218: PRIORITY_UPDATE before HEADERS (buffered)

$s = Test::Nginx::HTTP2->new();

# Send PRIORITY_UPDATE for stream that doesn't exist yet
h2_priority_update($s, 1, 'u=0');

# Now send the request
$sid = $s->new_stream({ path => '/small.html' });
$frames = $s->read(all => [{ sid => $sid, fin => 1 }]);

($data) = grep { $_->{type} eq 'DATA' } @$frames;
is($data->{data}, 'SEE-THIS', 'PRIORITY_UPDATE before HEADERS');

# RFC9218: PRIORITY_UPDATE applied to existing stream

$s = Test::Nginx::HTTP2->new();
$sid = $s->new_stream({ path => '/small.html' });

# Send PRIORITY_UPDATE for existing stream
h2_priority_update($s, $sid, 'u=1');

$frames = $s->read(all => [{ sid => $sid, fin => 1 }]);
($data) = grep { $_->{type} eq 'DATA' } @$frames;
is($data->{data}, 'SEE-THIS', 'PRIORITY_UPDATE for existing stream');

# RFC9218 Section 8: Upstream Priority header passed through proxy

$s = Test::Nginx::HTTP2->new();
$sid = $s->new_stream({ path => '/proxy/' });
$frames = $s->read(all => [{ sid => $sid, fin => 1 }]);

my ($headers) = grep { $_->{type} eq 'HEADERS' } @$frames;
is($headers->{headers}{priority}, 'u=0', 'upstream Priority header passed through');

# RFC9218 Section 8: Partial upstream priority preserves client parameters
# Client sends "u=5, i", upstream sends only "u=1"
# Per RFC9218 Section 8, absence of 'i' means server doesn't want to change it
# Result should be "u=1, i" (server's urgency, client's incremental preserved)

$s = Test::Nginx::HTTP2->new();
$sid = $s->new_stream({ headers => [
	{ name => ':method', value => 'GET', mode => 0 },
	{ name => ':scheme', value => 'http', mode => 0 },
	{ name => ':path', value => '/proxy_partial/', mode => 1 },
	{ name => ':authority', value => 'localhost', mode => 1 },
	{ name => 'priority', value => 'u=5, i', mode => 2 }]});
$frames = $s->read(all => [{ sid => $sid, fin => 1 }]);

($headers) = grep { $_->{type} eq 'HEADERS' } @$frames;
is($headers->{headers}{priority}, 'u=1, i',
	'partial upstream priority preserves client incremental');

###############################################################################

# Send PRIORITY_UPDATE frame (type 0x10) on stream 0
sub h2_priority_update {
	my ($s, $sid, $value) = @_;

	# PRIORITY_UPDATE frame format:
	# - Prioritized Stream ID (4 bytes, top bit reserved)
	# - Priority Field Value (variable)

	my $payload = pack('N', $sid) . $value;
	my $len = length($payload);

	# Frame header: length (3), type (1), flags (1), stream id (4)
	my $frame = pack('CCC', $len >> 16, ($len >> 8) & 0xff, $len & 0xff);
	$frame .= pack('C', 0x10);  # type = PRIORITY_UPDATE
	$frame .= pack('C', 0x00);  # flags
	$frame .= pack('N', 0);     # stream 0

	$frame .= $payload;

	$s->{socket}->syswrite($frame);
}

# Send PRIORITY_UPDATE frame on wrong stream (not stream 0)
sub h2_priority_update_bad_stream {
	my ($s, $target_sid, $value) = @_;

	my $payload = pack('N', $target_sid) . $value;
	my $len = length($payload);

	my $frame = pack('CCC', $len >> 16, ($len >> 8) & 0xff, $len & 0xff);
	$frame .= pack('C', 0x10);
	$frame .= pack('C', 0x00);
	$frame .= pack('N', 1);  # Wrong: should be stream 0

	$frame .= $payload;

	$s->{socket}->syswrite($frame);
}

###############################################################################
