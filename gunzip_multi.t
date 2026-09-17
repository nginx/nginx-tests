#!/usr/bin/perl

# Tests for gunzip filter module with multiple content-codings.

###############################################################################

use warnings;
use strict;

use Test::More;

use Socket qw/ CRLF /;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx qw/ :DEFAULT :gzip http_content /;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

eval { require IO::Compress::Gzip; };
plan(skip_all => 'IO::Compress::Gzip not found') if $@;

eval { require Compress::Zlib; };
plan(skip_all => 'Compress::Zlib not found') if $@;

my $t = Test::Nginx->new()->has(qw/http gunzip proxy/)->plan(10)
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

        location / {
            gunzip on;
            proxy_pass http://127.0.0.1:8081;
        }
    }
}

EOF

my $plain = 'hello gunzip world';

my $gzipped;
IO::Compress::Gzip::gzip(\$plain => \$gzipped);

my $deflated = Compress::Zlib::compress($plain);
my $deflated_then_gzipped;
IO::Compress::Gzip::gzip(\$deflated => \$deflated_then_gzipped);

$t->run_daemon(\&http_daemon, port(8081),
	$gzipped, $deflated_then_gzipped);
$t->run()->waitforsocket('127.0.0.1:' . port(8081));

###############################################################################

# single "gzip" (regression)

my $r = http_get('/single-gzip');
unlike($r, qr/Content-Encoding/, 'single gzip - no content encoding');
like(http_content($r), qr/^\Q$plain\E$/, 'single gzip - decompressed');

# "deflate, gzip": outer gzip is peeled, inner deflate bytes remain

$r = http_get('/deflate-gzip');
like($r, qr/Content-Encoding: deflate/,
	'deflate,gzip - remaining encoding preserved');
is(http_content($r), $deflated,
	'deflate,gzip - inner deflate bytes delivered verbatim');

# "gzip, deflate": gzip is not the last-applied coding, passed through

$r = http_get('/gzip-deflate');
like($r, qr/Content-Encoding: gzip, ?deflate/i,
	'gzip,deflate - encoding left intact');
is(http_content($r), $deflated_then_gzipped,
	'gzip,deflate - body passed through verbatim');

# client accepts gzip -- header and body must stay consistent

$r = http_gzip_request('/single-gzip');
like($r, qr/Content-Encoding: gzip/,
	'client accepts gzip - encoding preserved');
like($r, qr/\Q$gzipped\E/, 'client accepts gzip - body still gzipped');

# comma-separated list with several tokens before gzip

$r = http_get('/many-tokens');
like($r, qr/Content-Encoding: a,b,c,d,e,f/,
	'many tokens - gzip stripped, other tokens preserved');
like(http_content($r), qr/^\Q$plain\E$/, 'many tokens - decompressed');

###############################################################################

sub http_daemon {
	my ($port, $gzipped, $deflated_then_gzipped) = @_;

	my $server = IO::Socket::INET->new(
		Proto => 'tcp',
		LocalHost => "127.0.0.1:$port",
		Listen => 5,
		Reuse => 1
	)
		or die "Can't create listening socket: $!\n";

	local $SIG{PIPE} = 'IGNORE';

	my %responses = (
		'/single-gzip'  => ['gzip',                   $gzipped],
		'/deflate-gzip' => ['deflate, gzip',          $deflated_then_gzipped],
		'/gzip-deflate' => ['gzip, deflate',          $deflated_then_gzipped],
		'/many-tokens'  => ['a, b, c, d, e, f, gzip', $gzipped],
	);

	while (my $client = $server->accept()) {
		$client->autoflush(1);

		my $headers = '';
		my $uri;

		while (<$client>) {
			$headers .= $_;
			if ($headers =~ /^(?:GET|HEAD) (\S+)/m && !$uri) {
				$uri = $1;
			}
			last if (/^\x0d?\x0a?$/);
		}

		next if $headers eq '';
		next unless defined $uri && exists $responses{$uri};

		my ($ce, $body) = @{$responses{$uri}};

		print $client
			"HTTP/1.1 200 OK" . CRLF
			. "Connection: close" . CRLF
			. "Content-Type: text/plain" . CRLF
			. "Content-Encoding: $ce" . CRLF
			. "Content-Length: " . length($body) . CRLF
			. CRLF
			. $body;
	}
}

###############################################################################
