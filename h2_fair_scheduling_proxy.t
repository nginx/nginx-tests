#!/usr/bin/perl

# Tests for HTTP/2 fair scheduling with a synchronous unbuffered producer.

###############################################################################

use warnings;
use strict;

use Test::More;
use IO::Select;
use IO::Socket::INET;
use Socket qw/ CRLF /;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;
use Test::Nginx::HTTP2;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/http http_v2 proxy/)->plan(12)
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
        http2_fair_scheduling on;

        location / {
        }

        location /proxy/ {
            proxy_pass http://127.0.0.1:8081/;
            proxy_http_version 1.1;
            proxy_buffering off;
            proxy_buffer_size 1k;
        }
    }
}

EOF

my $size = 2**20;
my $body = join '', map { sprintf '%08x', $_ } 0 .. $size / 8 - 1;
$t->write_file('large', $body);
$t->run_daemon(\&http_daemon);
$t->run()->waitforsocket('127.0.0.1:' . port(8081));

###############################################################################

# The origin is independent of nginx.  Every upstream has body data ready while
# the downstream connection window is zero.  Tiny complete HTTP/1 chunks and a
# 1k proxy buffer make a single upstream read handler call the output filter
# repeatedly with short exhausted chains.  A send_chain-only quota would let
# that producer consume the entire grant through successive calls.

for my $kind ('length', 'chunked') {
	my $s = Test::Nginx::HTTP2->new();
	$s->h2_settings(0, 0x4 => 2**24);
	$s->read(all => [{ type => 'SETTINGS' }]);
	my $drain = $s->new_stream({ path => '/large' });
	$s->read(all => [{ length => 65535 }]);
	$s->h2_rst($drain, 8);

	my @ids;
	my @initial;
	for (1 .. 3) {
		my $sid = $s->new_stream({ path => "/proxy/$kind/$_" });
		push @ids, $sid;
		push @initial, @{$s->read(all => [{ sid => $sid, fin => 4 }])};
	}
	my @headers = grep { $_->{type} eq 'HEADERS' } @initial;
	is(scalar(grep { $_->{headers}{':status'} eq '200' } @headers),
		3, "$kind ready upstreams");
	is(bytes(\@initial), 0, "$kind connection window exhausted");

	$s->h2_window(192 * 1024);
	my $frames = $s->read(all => [{ length => 192 * 1024 }]);
	my %bytes;
	$bytes{$_->{sid}} += $_->{length}
		for grep { $_->{type} eq 'DATA' } @$frames;
	my @bytes = sort { $a <=> $b } map { $bytes{$_} || 0 } @ids;
	is(bytes($frames), 192 * 1024, "$kind full grant");
	ok($bytes[0] > 0 && $bytes[-1] - $bytes[0] <= 16384,
		"$kind synchronous producer bounded service")
		or diag join ' ', @bytes;

	$s->h2_window(3 * $size);
	push @$frames, @{$s->read(all => [
		map { { sid => $_, fin => 1 } } @ids
	])};
	my (%data, %fin);
	for (grep { $_->{type} eq 'DATA' } @$frames) {
		$data{$_->{sid}} .= $_->{data};
		$fin{$_->{sid}}++ if $_->{flags} & 1;
	}
	ok(!(grep { !defined $data{$_} || $data{$_} ne $body } @ids),
		"$kind complete payload integrity");
	is(scalar(grep { ($fin{$_} || 0) == 1 } @ids), 3,
		"$kind exactly one END_STREAM per response");
}

###############################################################################

sub bytes {
	my ($frames) = @_;
	my $n = 0;
	$n += $_->{length} for grep { $_->{type} eq 'DATA' } @$frames;
	return $n;
}

sub http_daemon {
	my $server = IO::Socket::INET->new(
		Proto => 'tcp',
		LocalHost => '127.0.0.1:' . port(8081),
		Listen => 16,
		Reuse => 1
	) or die "Can't create listening socket: $!\n";

	local $SIG{PIPE} = 'IGNORE';
	my $read = IO::Select->new($server);
	my $write = IO::Select->new();
	my %pending;

	while (1) {
		# Never block while filling one origin connection: nginx deliberately
		# stops reading it when the HTTP/2 connection has no credit.  Keep all
		# other origins readable so they are independently eligible peers.

		my ($r, $w) = IO::Select->select($read, $write, undef, 1);
		for (@{$r || []}) {
			my $client = $server->accept() or next;
			$client->autoflush(1);
			my $headers = '';
			while (<$client>) {
				$headers .= $_;
				last if /^\x0d?\x0a$/;
			}
			if ($headers !~ m!^GET /(length|chunked)/([123]) !) {
				close $client;
				next;
			}
			my ($kind, $n) = ($1, $2);
			my @priority = ('u=7, i', 'u=0', 'u=3, i=?0');
			my $wire = 'HTTP/1.1 200 OK' . CRLF
				. 'Connection: close' . CRLF
				. 'Priority: ' . $priority[$n - 1] . CRLF;
			if ($kind eq 'length') {
				$wire .= 'Content-Length: ' . length($body)
					. CRLF . CRLF . $body;
			} else {
				$wire .= 'Transfer-Encoding: chunked' . CRLF . CRLF;
				for (my $i = 0; $i < length($body); $i += 127) {
					my $chunk = substr($body, $i, 127);
					$wire .= sprintf('%x', length($chunk)) . CRLF
						. $chunk . CRLF;
				}
				$wire .= '0' . CRLF . CRLF;
			}
			$client->blocking(0);
			$pending{$client->fileno()} = $wire;
			$write->add($client);
		}

		for my $client (@{$w || []}) {
			my $fd = $client->fileno();
			my $n = $client->syswrite($pending{$fd}, 16384);
			next unless defined $n;
			substr($pending{$fd}, 0, $n, '');
			next if length $pending{$fd};
			$write->remove($client);
			delete $pending{$fd};
			close $client;
		}
	}
}

###############################################################################
