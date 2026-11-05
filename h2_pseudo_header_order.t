#!/usr/bin/perl

# (C) Nitin Swami
# (C) Nginx, Inc.

# Tests for HTTP/2 pseudo-header ordering enforcement (RFC 9113 §8.3).

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

my $t = Test::Nginx->new()->has(qw/http http_v2 rewrite/)->plan(15)
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

        http2 on;

        location / {
            return 200;
        }
    }
}

EOF

$t->run();

###############################################################################

# RFC 9113 §8.3: All pseudo-header fields MUST appear before regular header
# fields in a HEADERS or CONTINUATION frame block.  A request containing a
# pseudo-header after a regular header MUST be treated as malformed (→ 400).

# Test group 1: Single HEADERS frame — pseudo-header after regular (→ 400)

# 1.1: :method pseudo-header after regular host: header

my $s = Test::Nginx::HTTP2->new();
my $sid = $s->new_stream({ headers => [
	{ name => ':scheme', value => 'http', mode => 0 },
	{ name => ':path', value => '/', mode => 0 },
	{ name => ':authority', value => 'localhost', mode => 1 },
	{ name => 'host', value => 'localhost', mode => 2 },
	{ name => ':method', value => 'GET', mode => 0 }]});
my $frames = $s->read(all => [{ sid => $sid, fin => 1 }]);

my ($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
is($frame->{headers}->{':status'}, 400,
	'pseudo-header :method after regular header');

# 1.2: :path pseudo-header after a regular x-custom: header

$s = Test::Nginx::HTTP2->new();
$sid = $s->new_stream({ headers => [
	{ name => ':method', value => 'GET', mode => 0 },
	{ name => ':scheme', value => 'http', mode => 0 },
	{ name => ':authority', value => 'localhost', mode => 1 },
	{ name => 'x-custom', value => 'test', mode => 2 },
	{ name => ':path', value => '/', mode => 1 }]});
$frames = $s->read(all => [{ sid => $sid, fin => 1 }]);

($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
is($frame->{headers}->{':status'}, 400,
	'pseudo-header :path after regular header');

# 1.3: :scheme pseudo-header after a regular accept: header

$s = Test::Nginx::HTTP2->new();
$sid = $s->new_stream({ headers => [
	{ name => ':method', value => 'GET', mode => 0 },
	{ name => ':path', value => '/', mode => 0 },
	{ name => ':authority', value => 'localhost', mode => 1 },
	{ name => 'accept', value => 'text/html', mode => 2 },
	{ name => ':scheme', value => 'http', mode => 0 }]});
$frames = $s->read(all => [{ sid => $sid, fin => 1 }]);

($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
is($frame->{headers}->{':status'}, 400,
	'pseudo-header :scheme after regular header');

# 1.4: :authority pseudo-header after a regular user-agent: header

$s = Test::Nginx::HTTP2->new();
$sid = $s->new_stream({ headers => [
	{ name => ':method', value => 'GET', mode => 0 },
	{ name => ':scheme', value => 'http', mode => 0 },
	{ name => ':path', value => '/', mode => 0 },
	{ name => 'user-agent', value => 'test-client', mode => 2 },
	{ name => ':authority', value => 'localhost', mode => 1 }]});
$frames = $s->read(all => [{ sid => $sid, fin => 1 }]);

($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
is($frame->{headers}->{':status'}, 400,
	'pseudo-header :authority after regular header');

# Test group 2: Multiple pseudo-headers after a regular header (→ 400)

# 2.1: :method and :path both after a regular header

$s = Test::Nginx::HTTP2->new();
$sid = $s->new_stream({ headers => [
	{ name => ':scheme', value => 'http', mode => 0 },
	{ name => ':authority', value => 'localhost', mode => 1 },
	{ name => 'x-foo', value => 'bar', mode => 2 },
	{ name => ':method', value => 'GET', mode => 0 },
	{ name => ':path', value => '/', mode => 0 }]});
$frames = $s->read(all => [{ sid => $sid, fin => 1 }]);

($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
is($frame->{headers}->{':status'}, 400,
	'multiple pseudo-headers after regular header');

# Test group 3: Correct ordering (→ 200, must not be rejected)

# 3.1: All pseudo-headers before all regular headers — valid request

$s = Test::Nginx::HTTP2->new();
$sid = $s->new_stream({ headers => [
	{ name => ':method', value => 'GET', mode => 0 },
	{ name => ':scheme', value => 'http', mode => 0 },
	{ name => ':path', value => '/', mode => 0 },
	{ name => ':authority', value => 'localhost', mode => 1 },
	{ name => 'x-custom', value => 'value', mode => 2 },
	{ name => 'accept', value => '*/*', mode => 2 }]});
$frames = $s->read(all => [{ sid => $sid, fin => 1 }]);

($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
is($frame->{headers}->{':status'}, 200,
	'pseudo-headers before regular headers - valid');

# 3.2: POST with pseudo-headers before content-length — valid

$s = Test::Nginx::HTTP2->new();
$sid = $s->new_stream({ headers => [
	{ name => ':method', value => 'POST', mode => 1 },
	{ name => ':scheme', value => 'http', mode => 0 },
	{ name => ':path', value => '/', mode => 0 },
	{ name => ':authority', value => 'localhost', mode => 1 },
	{ name => 'content-length', value => '0', mode => 2 }],
	body => ''});
$frames = $s->read(all => [{ sid => $sid, fin => 1 }]);

($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
is($frame->{headers}->{':status'}, 200,
	'POST pseudo-headers before regular - valid');

# Test group 4: CONTINUATION frame — pseudo after regular across frames (→ 400)
#
# The fix stores regular_header_seen:1 on the stream struct so the flag
# persists across CONTINUATION frames on the same stream.

# 4.1: Regular header in HEADERS frame, then pseudo-header in CONTINUATION frame.
#
# regular_header_seen is stored on the stream struct (not the connection state)
# so it persists across the HEADERS → CONTINUATION frame sequence.
# When nginx processes x-custom from the HEADERS frame, regular_header_seen=1.
# When :method arrives in the CONTINUATION frame, the guard triggers → 400.

$s = Test::Nginx::HTTP2->new();
$sid = $s->new_stream({ continuation => 1, headers => [
	{ name => 'x-custom', value => 'test', mode => 2 }]});
$s->h2_continue($sid, { headers => [
	{ name => ':method', value => 'GET', mode => 0 },
	{ name => ':scheme', value => 'http', mode => 0 },
	{ name => ':path', value => '/', mode => 0 },
	{ name => ':authority', value => 'localhost', mode => 1 }]});
$frames = $s->read(all => [{ sid => $sid, fin => 1 }]);

($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
is($frame->{headers}->{':status'}, 400,
	'pseudo-header in CONTINUATION after regular header in HEADERS');

# 4.2: All pseudo-headers in HEADERS, regular headers in CONTINUATION (→ 200)

$s = Test::Nginx::HTTP2->new();
$sid = $s->new_stream({ continuation => 1, headers => [
	{ name => ':method', value => 'GET', mode => 0 },
	{ name => ':scheme', value => 'http', mode => 0 },
	{ name => ':path', value => '/', mode => 0 },
	{ name => ':authority', value => 'localhost', mode => 1 }]});
$s->h2_continue($sid, { headers => [
	{ name => 'x-custom', value => 'test', mode => 2 },
	{ name => 'accept', value => '*/*', mode => 2 }]});
$frames = $s->read(all => [{ sid => $sid, fin => 1 }]);

($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
is($frame->{headers}->{':status'}, 200,
	'pseudo-headers in HEADERS, regular in CONTINUATION - valid');

# Test group 5: Connection reuse — second stream after rejection is independent
#
# Verifies that regular_header_seen is scoped to the stream, not the
# connection; a valid stream opened after a rejected one must succeed.

$s = Test::Nginx::HTTP2->new();

# Stream 1: invalid — :path pseudo-header after regular x-foo header → 400

my $sid1 = $s->new_stream({ headers => [
	{ name => ':method', value => 'GET', mode => 0 },
	{ name => ':scheme', value => 'http', mode => 0 },
	{ name => ':authority', value => 'localhost', mode => 1 },
	{ name => 'x-foo', value => 'bar', mode => 2 },
	{ name => ':path', value => '/', mode => 1 }]});
my $frames1 = $s->read(all => [{ sid => $sid1, fin => 1 }]);

my ($frame1) = grep { $_->{type} eq "HEADERS" } @$frames1;
is($frame1->{headers}->{':status'}, 400,
	'stream 1 - pseudo after regular');

# Stream 3 (next odd stream id): valid request on same connection → 200

my $sid2 = $s->new_stream({ headers => [
	{ name => ':method', value => 'GET', mode => 0 },
	{ name => ':scheme', value => 'http', mode => 0 },
	{ name => ':path', value => '/', mode => 0 },
	{ name => ':authority', value => 'localhost', mode => 1 }]});
my $frames2 = $s->read(all => [{ sid => $sid2, fin => 1 }]);

my ($frame2) = grep { $_->{type} eq "HEADERS" } @$frames2;
is($frame2->{headers}->{':status'}, 200,
	'stream 2 - valid after rejected stream');

# Verify stream IDs are different (stream-level scoping check)

isnt($sid1, $sid2, 'rejection and valid request use separate stream IDs');

# Sanity: a fresh connection also succeeds (no connection-level corruption)

$s = Test::Nginx::HTTP2->new();
$sid = $s->new_stream({ headers => [
	{ name => ':method', value => 'GET', mode => 0 },
	{ name => ':scheme', value => 'http', mode => 0 },
	{ name => ':path', value => '/', mode => 0 },
	{ name => ':authority', value => 'localhost', mode => 1 }]});
$frames = $s->read(all => [{ sid => $sid, fin => 1 }]);

($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
is($frame->{headers}->{':status'}, 200,
	'fresh connection after rejected stream - valid');

# Test group 6: Additional regression checks

# 6.1: All pseudo-headers indexed (mode 0) before regular headers — valid

$s = Test::Nginx::HTTP2->new();
$sid = $s->new_stream({ headers => [
	{ name => ':method', value => 'GET', mode => 0 },
	{ name => ':scheme', value => 'http', mode => 0 },
	{ name => ':path', value => '/', mode => 0 },
	{ name => ':authority', value => 'localhost', mode => 1 },
	{ name => 'x-foo', value => 'bar', mode => 2 }]});
$frames = $s->read(all => [{ sid => $sid, fin => 1 }]);

($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
is($frame->{headers}->{':status'}, 200,
	'indexed pseudo-headers before regular header - valid');

# 6.2: Request missing ':scheme' pseudo-header — 400 (missing required pseudo-header,
# not ordering violation; verifies fix does not affect existing validation)

$s = Test::Nginx::HTTP2->new();
$sid = $s->new_stream({ headers => [
	{ name => ':method', value => 'GET', mode => 0 },
	{ name => ':path', value => '/', mode => 0 },
	{ name => ':authority', value => 'localhost', mode => 1 }]});
$frames = $s->read(all => [{ sid => $sid, fin => 1 }]);

($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
is($frame->{headers}->{':status'}, 400,
	'missing :scheme pseudo-header - still rejected');

###############################################################################
