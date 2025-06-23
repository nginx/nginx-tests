#!/usr/bin/perl

# (C) Eugene Grebenschikov

# Tests for early hints via HTTP/3.

###############################################################################

use warnings;
use strict;

use Test::More;
use Socket qw/ CRLF /;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;
use Test::Nginx::HTTP3;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/http http_v3 proxy cryptx/);

plan(skip_all => "not yet") unless $t->has_version('1.29.0');

$t->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    map $server_protocol $early_hints {
        "HTTP/3.0" 1;
    }

    early_hints $early_hints;

    ssl_certificate_key localhost.key;
    ssl_certificate localhost.crt;

    server {
        listen       127.0.0.1:%%PORT_8980_UDP%% quic;
        server_name  localhost;

        proxy_read_timeout 2s;
        proxy_connect_timeout 2s;
        proxy_buffer_size 4k;

        location / {
            proxy_pass http://127.0.0.1:8081;
        }

        location ~* onoff {
            early_hints $arg_hints;
            proxy_pass http://127.0.0.1:8081;
        }
    }
}

EOF

$t->write_file('openssl.conf', <<'EOF');
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

$t->run_daemon(\&http_daemon)->waitforsocket('127.0.0.1:' . port(8081))
	or die 'No socket 127.0.0.1:' . port(8081) . ' open';

$t->run()->plan(6);

###############################################################################

my $s = Test::Nginx::HTTP3->new();

$s->new_stream({ path => '/early-hints' });
my $headers = get_headers($s);
is(${headers}->{':status'}, 103, '103 - pass early hints');
is(${headers}->{'link'}, '<https://example.com>; rel="preconnect"',
	'header - pass early hints');
$headers = get_headers($s, all => [{ fin => 1 }]);
is(${headers}->{':status'}, 200, '200 - pass early hints');

$s->new_stream({ path => '/early-hints-onoff' });
$headers = get_headers($s, all => [{ fin => 1 }]);
is(${headers}->{':status'}, 200, '200 - don\'t pass early hints');

$s->new_stream({ path => '/' });
$headers = get_headers($s, all => [{ fin => 1 }]);
is(${headers}->{':status'}, 200, '200 - no early hints');

$s->new_stream({ path => '/huge-early-hints' });
$headers = get_headers($s, all => [{ fin => 1 }]);
is(${headers}->{':status'}, 502, '502 - too big early hints');

###############################################################################

sub get_headers {
	my ($s, %extra) = @_;

	$extra{all} = $extra{all} || [];

	while (my $frames = $s->read(%extra)) {
		my ($frame) = grep { $_->{type} eq "HEADERS" } @{$frames};
		return $frame->{headers}
			if defined $frame->{headers} || !scalar @{$frames};
	}
}

###############################################################################

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
		my $uri = '';

		while (<$client>) {
			$headers .= $_;
			last if (/^\x0d?\x0a?$/);
		}

		$uri = $1 if $headers =~ /^\S+\s+([^ ]+)\s+HTTP/i;

		if ($uri =~ /early/) {
			my $links  = 'Link: <https://example.com>; rel="preconnect"';
			$links .= $uri =~ /huge/ ? (CRLF . $links) x 100 : '';
			print $client <<"EOF";
HTTP/1.1 103 Early Hints
$links

EOF
			select undef, undef, undef, 0.2;
		}

		print $client <<'EOF';
HTTP/1.1 200 OK
Connection: close

EOF

		close $client;
	}
}

###############################################################################
