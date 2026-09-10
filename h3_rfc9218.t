#!/usr/bin/perl

# (C) Andrew Clayton
# (C) Nginx, Inc.

# Tests for HTTP/3 RFC9218 Extensible Prioritization Scheme.

###############################################################################

use warnings;
use strict;

use Test::More;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;
use Test::Nginx::HTTP3;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

# H3_ID_ERROR and H3_FRAME_ERROR from RFC 9114, Section 8.1.

use constant H3_FRAME_ERROR => 0x106;
use constant H3_ID_ERROR    => 0x108;

# RFC 9218 PRIORITY_UPDATE frame types (Section 7.1).

use constant PRIORITY_UPDATE_REQUEST => 0xf0700;
use constant PRIORITY_UPDATE_PUSH    => 0xf0701;

my $t = Test::Nginx->new()->has(qw/http http_v3 proxy rewrite cryptx/)
	->has_daemon('openssl')->plan(13)
	->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    ssl_certificate_key localhost.key;
    ssl_certificate localhost.crt;

    server {
        listen       127.0.0.1:%%PORT_8980_UDP%% quic;
        listen       127.0.0.1:8081;
        server_name  localhost;

        location / { }

        location /proxy/ {
            proxy_pass http://127.0.0.1:8081/upstream/;
        }

        location /proxy_partial/ {
            proxy_pass http://127.0.0.1:8081/partial/;
        }

        location /proxy_partial_i/ {
            proxy_pass http://127.0.0.1:8081/partial_i/;
        }

        location /upstream/ {
            add_header Priority "u=0";
            return 200 "upstream response";
        }

        location /partial/ {
            # Only urgency, no incremental - tests RFC9218 Section 8
            add_header Priority "u=1";
            return 200 "partial priority";
        }

        location /partial_i/ {
            # Only incremental, no urgency - lets the client urgency show
            # through the merge so it can be observed in the response.
            add_header Priority "i";
            return 200 "partial priority";
        }
    }
}

EOF

$t->write_file('openssl.conf', <<EOF);
[ req ]
default_bits = 2048
encrypt_key = no
distinguished_name = req_distinguished_name
[ req_distinguished_name ]
EOF

my $d = $t->testdir();

foreach my $name ('localhost') {
	system('openssl req -x509 -new '
		. "-config $d/openssl.conf -subj /CN=$name/ "
		. "-out $d/$name.crt -keyout $d/$name.key "
		. ">>$d/openssl.out 2>&1") == 0
		or die "Can't create certificate for $name: $!\n";
}

$t->run();

$t->write_file('small.html', 'SEE-THIS');

###############################################################################

# RFC9218: Priority header with urgency

my $s = Test::Nginx::HTTP3->new();
my $sid = $s->new_stream({ headers => [
	{ name => ':method', value => 'GET' },
	{ name => ':scheme', value => 'http' },
	{ name => ':path', value => '/small.html' },
	{ name => ':authority', value => 'localhost' },
	{ name => 'priority', value => 'u=1' }]});
my $frames = $s->read(all => [{ sid => $sid, fin => 1 }]);

my ($data) = grep { $_->{type} eq 'DATA' } @$frames;
is($data->{data}, 'SEE-THIS', 'priority header u=1');

# RFC9218: Priority header with urgency and incremental

$s = Test::Nginx::HTTP3->new();
$sid = $s->new_stream({ headers => [
	{ name => ':method', value => 'GET' },
	{ name => ':scheme', value => 'http' },
	{ name => ':path', value => '/small.html' },
	{ name => ':authority', value => 'localhost' },
	{ name => 'priority', value => 'u=3, i' }]});
$frames = $s->read(all => [{ sid => $sid, fin => 1 }]);

($data) = grep { $_->{type} eq 'DATA' } @$frames;
is($data->{data}, 'SEE-THIS', 'priority header u=3, i');

# RFC9218: Priority header with i=?0 (explicit non-incremental)

$s = Test::Nginx::HTTP3->new();
$sid = $s->new_stream({ headers => [
	{ name => ':method', value => 'GET' },
	{ name => ':scheme', value => 'http' },
	{ name => ':path', value => '/small.html' },
	{ name => ':authority', value => 'localhost' },
	{ name => 'priority', value => 'u=5, i=?0' }]});
$frames = $s->read(all => [{ sid => $sid, fin => 1 }]);

($data) = grep { $_->{type} eq 'DATA' } @$frames;
is($data->{data}, 'SEE-THIS', 'priority header u=5, i=?0');

# RFC9218: Malformed priority header uses defaults

$s = Test::Nginx::HTTP3->new();
$sid = $s->new_stream({ headers => [
	{ name => ':method', value => 'GET' },
	{ name => ':scheme', value => 'http' },
	{ name => ':path', value => '/small.html' },
	{ name => ':authority', value => 'localhost' },
	{ name => 'priority', value => 'invalid' }]});
$frames = $s->read(all => [{ sid => $sid, fin => 1 }]);

($data) = grep { $_->{type} eq 'DATA' } @$frames;
is($data->{data}, 'SEE-THIS', 'malformed priority header');

# RFC9218: PRIORITY_UPDATE before HEADERS (buffered)

$s = Test::Nginx::HTTP3->new();

# Send PRIORITY_UPDATE for the first request stream (id 0) before its HEADERS
$s->priority_update(PRIORITY_UPDATE_REQUEST, 0, 'u=0');

$sid = $s->new_stream({ path => '/small.html' });
$frames = $s->read(all => [{ sid => $sid, fin => 1 }]);

($data) = grep { $_->{type} eq 'DATA' } @$frames;
is($data->{data}, 'SEE-THIS', 'PRIORITY_UPDATE before HEADERS');

# RFC9218: PRIORITY_UPDATE applied to existing stream

$s = Test::Nginx::HTTP3->new();
$sid = $s->new_stream({ path => '/small.html' });

$s->priority_update(PRIORITY_UPDATE_REQUEST, $sid, 'u=1');

$frames = $s->read(all => [{ sid => $sid, fin => 1 }]);
($data) = grep { $_->{type} eq 'DATA' } @$frames;
is($data->{data}, 'SEE-THIS', 'PRIORITY_UPDATE for existing stream');

# RFC9218: PRIORITY_UPDATE with an unknown extension member is not discarded
# wholesale; recognized members ("u"/"i") are still applied alongside it.

$s = Test::Nginx::HTTP3->new();
$sid = $s->new_stream({ path => '/small.html' });

$s->priority_update(PRIORITY_UPDATE_REQUEST, $sid, 'u=1, ext="value"');

$frames = $s->read(all => [{ sid => $sid, fin => 1 }]);
($data) = grep { $_->{type} eq 'DATA' } @$frames;
is($data->{data}, 'SEE-THIS',
	'PRIORITY_UPDATE with unknown member applies "u"');

# RFC9218: a comma inside a quoted string is not a dictionary member
# separator, so it must not be mistaken for a "u"/"i" member boundary.  The
# whole value is a single unknown "x" member; per the complete-set semantics
# it resets the recognized parameters to their defaults, and the stream is
# served rather than the connection being torn down.  (The reset itself is
# asserted separately below via the proxy pass-through.)

$s = Test::Nginx::HTTP3->new();
$sid = $s->new_stream({ path => '/small.html' });

$s->priority_update(PRIORITY_UPDATE_REQUEST, $sid, 'x="foo,u=0"');

$frames = $s->read(all => [{ sid => $sid, fin => 1 }]);
($data) = grep { $_->{type} eq 'DATA' } @$frames;
is($data->{data}, 'SEE-THIS',
	'PRIORITY_UPDATE with comma in quoted string');

# RFC9218: PRIORITY_UPDATE for a push id - H3_ID_ERROR
#
# nginx advertises no push capability, so it never grants a push id; a
# PRIORITY_UPDATE referencing a push id is always out of range.

$s = Test::Nginx::HTTP3->new();
$s->priority_update(PRIORITY_UPDATE_PUSH, 0, 'u=1');

$frames = $s->read(all => [{ type => 'CONNECTION_CLOSE' }]);
my ($cc) = grep { $_->{type} eq 'CONNECTION_CLOSE' } @$frames;
is($cc->{error}, H3_ID_ERROR, 'PRIORITY_UPDATE push id - H3_ID_ERROR');

# RFC9218: PRIORITY_UPDATE with empty payload - H3_FRAME_ERROR
#
# The frame carries a mandatory Prioritized Element ID and so cannot have an
# empty payload.

$s = Test::Nginx::HTTP3->new();
$s->priority_update(PRIORITY_UPDATE_REQUEST, undef, undef);

$frames = $s->read(all => [{ type => 'CONNECTION_CLOSE' }]);
($cc) = grep { $_->{type} eq 'CONNECTION_CLOSE' } @$frames;
is($cc->{error}, H3_FRAME_ERROR, 'PRIORITY_UPDATE empty payload - H3_FRAME_ERROR');

# RFC9218 Section 8: Upstream Priority header passed through proxy

$s = Test::Nginx::HTTP3->new();
$sid = $s->new_stream({ path => '/proxy/' });
$frames = $s->read(all => [{ sid => $sid, fin => 1 }]);

my ($headers) = grep { $_->{type} eq 'HEADERS' } @$frames;
is($headers->{headers}{priority}, 'u=0', 'upstream Priority header passed through');

# RFC9218 Section 8: Partial upstream priority preserves client parameters
# Client sends "u=5, i", upstream sends only "u=1"
# Per RFC9218 Section 8, absence of 'i' means server doesn't want to change it
# Result should be "u=1, i" (server's urgency, client's incremental preserved)

$s = Test::Nginx::HTTP3->new();
$sid = $s->new_stream({ headers => [
	{ name => ':method', value => 'GET' },
	{ name => ':scheme', value => 'http' },
	{ name => ':path', value => '/proxy_partial/' },
	{ name => ':authority', value => 'localhost' },
	{ name => 'priority', value => 'u=5, i' }]});
$frames = $s->read(all => [{ sid => $sid, fin => 1 }]);

($headers) = grep { $_->{type} eq 'HEADERS' } @$frames;
is($headers->{headers}{priority}, 'u=1, i',
	'partial upstream priority preserves client incremental');

# RFC9218 Section 7: a PRIORITY_UPDATE frame communicates a complete set of
# priority parameters, so an omitted parameter is a signal to use its default.
# A value whose only members are unknown extensions therefore resets the
# recognized parameters to their defaults rather than retaining the earlier
# signal.  The client first sets "u=5" in the Priority header, then sends an
# extension-only PRIORITY_UPDATE; the /partial_i/ upstream sets only "i" (no
# urgency), so the effective urgency echoed back is the client's.  A result of
# "i" (urgency reset to the default 3) proves the update was applied; "u=5, i"
# would prove it was wrongly discarded.

$s = Test::Nginx::HTTP3->new();
$sid = $s->new_stream({ headers => [
	{ name => ':method', value => 'GET' },
	{ name => ':scheme', value => 'http' },
	{ name => ':path', value => '/proxy_partial_i/' },
	{ name => ':authority', value => 'localhost' },
	{ name => 'priority', value => 'u=5' }]});
$s->priority_update(PRIORITY_UPDATE_REQUEST, $sid, 'a=1');
$frames = $s->read(all => [{ sid => $sid, fin => 1 }]);

($headers) = grep { $_->{type} eq 'HEADERS' } @$frames;
is($headers->{headers}{priority}, 'i',
	'extension-only PRIORITY_UPDATE resets to defaults');

###############################################################################
