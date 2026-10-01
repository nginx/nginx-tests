#!/usr/bin/perl

# (C) Sepuri Sai Krishna

# Tests for hop-by-hop headers in HTTP 103 Early Hints responses.

###############################################################################

use warnings;
use strict;

use Test::More;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;
use Test::Nginx::HTTP2;
use Test::Nginx::HTTP3;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my @hop = qw(connection content-length transfer-encoding keep-alive upgrade);

my $t = Test::Nginx->new()->has(qw/http http_v2 http_v3 cryptx proxy/)
	->has_daemon('openssl');

$t->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    server {
        listen       127.0.0.1:8080;
        listen       127.0.0.1:%%PORT_8980_UDP%% quic;
        server_name  localhost;

        ssl_certificate_key localhost.key;
        ssl_certificate localhost.crt;

        http2 on;
        early_hints 1;

        location / {
            proxy_pass http://127.0.0.1:8081;
            proxy_http_version 1.1;
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

$t->try_run('no early_hints')->plan(10);

$t->run_daemon(\&http_daemon);
$t->waitforsocket('127.0.0.1:' . port(8081));

###############################################################################

# the upstream sends hop-by-hop and framing header fields in its 103
# response; they are not to be passed to the client

my $r = get('/');
my ($hints) = $r =~ /(.*?)\x0d\x0a\x0d\x0a/s;

my $hop = join '|', @hop;

like($r, qr/103.*Link.*200 OK.*SEE-THIS/s, 'early hints');
unlike($hints, qr/^(?:$hop):/mi, 'no hop-by-hop headers');

# HTTP/2

my ($s, $frames, $frame);
$s = Test::Nginx::HTTP2->new();
$frames = $s->read(all => [{ sid => $s->new_stream(), fin => 1 }]);
@$frames = grep { $_->{type} =~ "HEADERS|DATA" } @$frames;

$frame = shift @$frames;
is($frame->{headers}{':status'}, 103, 'h2 early hints');
ok($frame->{headers}{'link'}, 'h2 early header');
is(join(' ', grep { defined $frame->{headers}{$_} } @hop), '',
	'h2 no hop-by-hop headers');

$frame = shift @$frames;
is($frame->{headers}{':status'}, 200, 'h2 header');

# HTTP/3

$s = Test::Nginx::HTTP3->new();
$frames = $s->read(all => [{ sid => $s->new_stream(), fin => 1 }]);
@$frames = grep { $_->{type} =~ "HEADERS|DATA" } @$frames;

$frame = shift @$frames;
is($frame->{headers}{':status'}, 103, 'h3 early hints');
ok($frame->{headers}{'link'}, 'h3 early header');
is(join(' ', grep { defined $frame->{headers}{$_} } @hop), '',
	'h3 no hop-by-hop headers');

$frame = shift @$frames;
is($frame->{headers}{':status'}, 200, 'h3 header');

###############################################################################

sub get {
	my ($uri) = @_;
	http(<<EOF);
GET $uri HTTP/1.1
Host: localhost
Connection: close

EOF
}

sub http_daemon {
	my $server = IO::Socket::INET->new(
		Proto => 'tcp',
		LocalHost => '127.0.0.1:' . port(8081),
		Listen => 5,
		Reuse => 1
	)
		or die "Can't create listening socket: $!\n";

	local $SIG{PIPE} = 'IGNORE';

	while (my $client = $server->accept()) {
		$client->autoflush(1);

		my $headers = '';

		while (<$client>) {
			$headers .= $_;
			last if (/^\x0d?\x0a?$/);
		}

		next if $headers eq '';

		print $client <<'EOF';
HTTP/1.1 103
Link: </style.css>; rel=preload; as=style
Connection: close
Content-Length: 42
Transfer-Encoding: chunked
Keep-Alive: timeout=1
Upgrade: h2c

EOF

		print $client <<'EOF';
HTTP/1.1 200 OK
Connection: close

EOF

		print $client 'SEE-THIS';
	}
}

###############################################################################
