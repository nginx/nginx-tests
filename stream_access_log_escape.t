#!/usr/bin/perl

# (C) Sergey Kandaurov
# (C) Nginx, Inc.

# Stream tests for access_log with escape parameter.

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
	->has(qw/stream stream_map stream_return stream_ssl_preread/)
	->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

stream {
    %%TEST_GLOBALS_STREAM%%

    map $pid $a {
        default '" \ "';
    }
    map $pid $b {
        default "foo";
    }
    map $pid $c {
        default "%%UTF8%%";
    }

    log_format json     escape=json     $a$b$upstream_addr;
    log_format default  escape=default  $a$b$upstream_addr;
    log_format utf8     escape=json     $c;
    log_format alpn     escape=json     $ssl_preread_alpn_protocols;

    server {
        listen       127.0.0.1:8080;
        return       ok;

        access_log %%TESTDIR%%/json.log json;
        access_log %%TESTDIR%%/test.log default;
        access_log %%TESTDIR%%/utf8.log utf8;
    }

    server {
        listen       127.0.0.1:8081;
        return       ok;

        ssl_preread  on;

        access_log %%TESTDIR%%/alpn.log alpn;
    }
}

EOF

# valid UTF-8, a stray continuation byte, a surrogate half, an overlong

my $conf = $t->read_file('nginx.conf');
$conf =~ s/%%UTF8%%/\xc3\xa9|\x80|\xed\xa0\x80|\xc0\x80/;
$t->write_file('nginx.conf', $conf);

$t->run()->plan(6);

###############################################################################

http_get('/');

# an ALPN protocol name is copied out of the ClientHello unvalidated

stream('127.0.0.1:' . port(8081))->io(client_hello("valid-\xe2\x98\x83"));
stream('127.0.0.1:' . port(8081))->io(client_hello("c1-\x85"));
stream('127.0.0.1:' . port(8081))->io(client_hello("ff-\xff"));

$t->stop();

is($t->read_file('json.log'), '\" \\\\ \"foo' . "\n", 'json');
is($t->read_file('test.log'), '\x22 \x5C \x22foo-' . "\n", 'default');

my @alpn = split /\n/, $t->read_file('alpn.log');

# a value needing no escaping is copied without reaching the escaper

is($alpn[0], "valid-\xe2\x98\x83", 'json utf8 alpn');

TODO: {
local $TODO = 'not yet' unless $t->has_version('1.31.9');

is($t->read_file('utf8.log'),
	"\xc3\xa9|\xef\xbf\xbd|\xef\xbf\xbd\xef\xbf\xbd\xef\xbf\xbd"
	. "|\xef\xbf\xbd\xef\xbf\xbd\n", 'json invalid utf8');

is($alpn[1], "c1-\xef\xbf\xbd", 'json invalid utf8 alpn');
is($alpn[2], "ff-\xef\xbf\xbd", 'json invalid utf8 alpn ff');

}

###############################################################################

sub client_hello {
	my ($alpn) = @_;

	my $protocol = pack("C", length($alpn)) . $alpn;
	my $list = pack("n", length($protocol)) . $protocol;
	my $ext = pack("nn", 0x0010, length($list)) . $list;

	my $body = "\x03\x03" . ("A" x 32) . "\x00" . pack("n", 2) . "\x00\x2f"
		. "\x01\x00" . pack("n", length($ext)) . $ext;
	my $hs = "\x01" . substr(pack("N", length($body)), 1) . $body;

	return "\x16\x03\x01" . pack("n", length($hs)) . $hs;
}

###############################################################################
