#!/usr/bin/perl

# Tests for CRLF injection through runtime-expanded variables used by
# HTTP/1.x proxy request serialization.

###############################################################################


use warnings;
use strict;

use Test::More;
use IO::Socket::INET;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/http proxy/)->plan(6);

$t->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        location /uri/ {
            proxy_pass http://127.0.0.1:8081/$uri;
        }

        location /header/ {
            proxy_set_header X-Normalized-URI $uri;
            proxy_pass http://127.0.0.1:8081;
        }
    }
}

EOF

$t->run_daemon(\&http_daemon, $t->testdir());
$t->run()->waitforsocket('127.0.0.1:' . port(8081));

###############################################################################

my $crlf = '%0d%0aX-Injected:%20yes';
my $lf = '%0aX-Injected:%20yes';
my $cr = '%0dX-Injected:%20yes';
my ($response, $upstream);

($response, $upstream) = get($t, '/uri/' . $crlf);
like($response, qr/500 Internal Server Error/,
    'proxy_pass uri rejects CRLF');
unlike($upstream, qr/X-Injected:\s*yes/i,
    'proxy_pass uri does not inject backend header');

($response, $upstream) = get($t, '/header/' . $crlf);
like($response, qr/500 Internal Server Error/,
    'proxy_set_header rejects CRLF value');
unlike($upstream, qr/X-Injected:\s*yes/i,
    'proxy_set_header does not inject backend header');

like((get($t, '/header/' . $lf))[0], qr/500 Internal Server Error/,
    'proxy_set_header rejects LF value');
like((get($t, '/header/' . $cr))[0], qr/500 Internal Server Error/,
    'proxy_set_header rejects CR value');

###############################################################################

sub get {
    my ($test, $uri) = @_;

    $test->write_file('upstream.raw', '');

    my $response = http(<<EOF);
GET $uri HTTP/1.1
Host: localhost
Connection: close

EOF

    select undef, undef, undef, 0.1;

    return ($response, $test->read_file('upstream.raw'));
}

sub http_daemon {
    my ($testdir) = @_;

    local $SIG{PIPE} = 'IGNORE';

    my $server = IO::Socket::INET->new(
        Proto => 'tcp',
        LocalAddr => '127.0.0.1',
        LocalPort => port(8081),
        Listen => 5,
        Reuse => 1,
    ) or die "cannot listen on 127.0.0.1:" . port(8081) . ": $!";

    while (my $client = $server->accept()) {
        my $request = '';

        while ($request !~ /\x0d\x0a\x0d\x0a/s) {
            my $n = sysread($client, my $buf, 4096);
            last if !defined $n || $n == 0;
            $request .= $buf;
        }

        if (!length $request) {
            close $client;
            next;
        }

        open my $raw, '>>', "$testdir/upstream.raw"
            or die "cannot append to upstream.raw: $!";
        binmode $raw;
        print $raw $request;
        close $raw;

        print $client "HTTP/1.1 200 OK\x0d\x0a";
        print $client "Connection: close\x0d\x0a";
        print $client "Content-Length: " . length($request) . "\x0d\x0a";
        print $client "\x0d\x0a";
        print $client $request;

        close $client;
    }
}

###############################################################################
