#!/usr/bin/perl

# (C) Nginx, Inc.

# Tests for HTTP/2 lingering close with kernel TLS.

###############################################################################

use warnings;
use strict;

use Test::More;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx qw/ :DEFAULT http_get /;
use Test::Nginx::HTTP2;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/http http_ssl http_v2 socket_ssl_alpn/)
	->has_daemon('openssl');

plan(skip_all => 'no kernel TLS') unless -r '/proc/net/tls_stat';

$t->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    server {
        listen       127.0.0.1:8443 ssl;
        server_name  localhost;

        http2 on;

        ssl_certificate_key localhost.key;
        ssl_certificate localhost.crt;

        ssl_conf_command Options KTLS;

        keepalive_requests 1;

        location / {
            return 200;
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

$t->try_run('no ssl_conf_command');

my $rx = tls_rx();
http_get('/', SSL => 1);

plan(skip_all => 'no kernel TLS receive offload') unless tls_rx() > $rx;

$t->plan(2);

$t->todo_alerts();

###############################################################################

# the connection is closed after the response, the client "close notify"
# alert is read during lingering close

my $s = Test::Nginx::HTTP2->new(undef, socket => http('', start => 1,
	SSL => 1, SSL_alpn_protocols => [ 'h2' ]));
my $sid = $s->new_stream();
my $frames = $s->read(all => [{ sid => $sid, fin => 1 }, { type => 'GOAWAY' }]);

my ($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
is($frame->{headers}->{':status'}, 200, 'response');

($frame) = grep { $_->{type} eq "GOAWAY" } @$frames;
ok($frame, 'goaway');

$s->{socket}->close();

select undef, undef, undef, 0.2;

$t->stop();

###############################################################################

sub tls_rx {
	open my $fh, '<', '/proc/net/tls_stat' or return 0;
	my ($n) = map { /^TlsRxSw\s+(\d+)/ ? $1 : () } <$fh>;
	return $n || 0;
}

###############################################################################
