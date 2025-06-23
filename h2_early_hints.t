#!/usr/bin/perl

# (C) Eugene Grebenschikov

# Tests for early hints via HTTP/2.

###############################################################################

use warnings;
use strict;

use Test::More;
use Socket qw/ CRLF /;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;
use Test::Nginx::HTTP2;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/http http_v2 proxy/);

plan(skip_all => "not yet") unless $t->has_version('1.29.0');

$t->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    map $server_protocol $early_hints {
        "HTTP/2.0" 1;
    }

    early_hints $early_hints;

    server {
        listen       127.0.0.1:8080;
        http2 on;
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

$t->run_daemon(\&http_daemon)->waitforsocket('127.0.0.1:' . port(8081))
	or die 'No socket 127.0.0.1:' . port(8081) . ' open';

$t->run()->plan(6);

###############################################################################

my $s = Test::Nginx::HTTP2->new();

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

	my ($frame) = grep { $_->{type} eq "HEADERS" } @{$s->read(%extra)};

	return $frame->{headers};
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
