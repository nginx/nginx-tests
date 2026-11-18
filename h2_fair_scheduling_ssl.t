#!/usr/bin/perl

# Tests for opt-in HTTP/2 fair scheduling over TLS.

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

my $t = Test::Nginx->new()
	->has(qw/http http_ssl http_v2 proxy socket_ssl_alpn/)
	->has_daemon('openssl');

plan(skip_all => 'no ALPN support in OpenSSL')
	if $t->has_module('OpenSSL') and not $t->has_feature('openssl:1.0.2');

$t->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    http2 on;
    ssl_certificate_key localhost.key;
    ssl_certificate localhost.crt;

    server {
        listen       127.0.0.1:8084 ssl;
        server_name  localhost;
        ssl_buffer_size 16k;
        http2_fair_scheduling on;

        location /proxy/ {
            proxy_pass http://127.0.0.1:8086/;
            proxy_http_version 1.1;
            proxy_buffering off;
            proxy_buffer_size 1k;
        }
    }

    server {
        listen       127.0.0.1:8084 ssl;
        server_name  off.local;
        ssl_buffer_size 16k;
        http2_fair_scheduling off;
    }

    server {
        listen       127.0.0.1:8085 ssl;
        server_name  localhost;
        ssl_buffer_size 4k;
        http2_fair_scheduling on;

        location /proxy/ {
            proxy_pass http://127.0.0.1:8086/;
            proxy_http_version 1.1;
            proxy_buffering off;
            proxy_buffer_size 1k;
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
system('openssl req -x509 -new '
	. "-config $d/openssl.conf -subj /CN=localhost/ "
	. "-out $d/localhost.crt -keyout $d/localhost.key "
	. ">>$d/openssl.out 2>&1") == 0
	or die "Can't create certificate: $!\n";

my $size = 2**20;
my $body = join '', map { sprintf '%08x', $_ } 0 .. $size / 8 - 1;
$t->write_file('large', $body);
$t->run_daemon(\&http_daemon);
$t->run()->plan(53);
$t->waitforsocket('127.0.0.1:' . port(8086));

###############################################################################

# The initial stream consumes the connection window before the measured
# responses are opened.  All three measured HEADERS must arrive while their
# payloads are blocked.  Connection credit then controls exact DATA budgets,
# independently of TLS record boundaries and ssl_buffer_size.

for my $port (8084, 8085) {
	my $buffer = $port == 8084 ? '16k' : '4k';
	for my $case (
		[ 'unmarked', (undef) x 3 ],
		[ 'mixed', 'u=7, i', 'u=0, i=?0', 'u=3' ]
	) {
		my ($kind, @priority) = @$case;
		my $authority = $port == 8084 && $kind eq 'unmarked'
			? 'off.local' : 'localhost';
		exercise($port, $authority, '/large', \@priority,
			"static $buffer $kind");
	}

	# Short complete HTTP/1 chunks exercise repeated unbuffered producer
	# calls behind the TLS output filter, with mixed upstream priorities.

	exercise($port, 'localhost', '/proxy/',
		['u=7, i', 'u=0', 'u=3, i=?0'], "unbuffered proxy $buffer");
}

# SNI selects the initial server before HTTP/2 initialization.  The off.local
# policy must survive a later :authority selecting the enabled server.  The
# inverse transition is covered by the first static 16k case above.

my ($s, $ids) = ready(8084, 'off.local', 'localhost', '/large',
	['u=7', 'u=0', 'u=7'], 'SNI explicit off');
$s->h2_window(49152);
my $frames = $s->read(all => [{ length => 49152 }]);
my %seen;
is(join(' ', grep { !$seen{$_}++ }
	map { $_->{sid} } grep { $_->{type} eq 'DATA' } @$frames),
	$ids->[1], 'SNI explicit off preserves urgency');
complete($s, $ids, $frames, 'SNI explicit off');

###############################################################################

sub exercise {
	my ($port, $authority, $path, $priority, $name) = @_;
	my ($s, $ids) = ready($port, 'localhost', $authority, $path,
		$priority, $name);
	my @frames;
	for (1 .. 6) {
		$s->h2_window(8192);
		push @frames, @{$s->read(all => [{ length => 8192 }])};
	}
	balanced(\@frames, $ids, 49152, "$name small grants");
	$s->h2_window(192 * 1024);
	my $frames = $s->read(all => [{ length => 192 * 1024 }]);
	balanced($frames, $ids, 192 * 1024, "$name large grant");
	push @frames, @$frames;
	complete($s, $ids, \@frames, $name);
}

sub ready {
	my ($port, $sni, $authority, $path, $priority, $name) = @_;
	my $sock = http('', start => 1, SSL => 1,
		PeerAddr => '127.0.0.1:' . port($port),
		SSL_hostname => $sni, SSL_alpn_protocols => ['h2']);
	die "Can't establish TLS connection\n" unless $sock;
	is($sock->alpn_selected(), 'h2', "$name negotiates h2");
	my $s = Test::Nginx::HTTP2->new(undef, socket => $sock);
	$s->h2_settings(0, 0x4 => 2**24);
	$s->read(all => [{ type => 'SETTINGS' }]);
	my $drain = $s->new_stream({ path => '/large', host => $sni });
	$s->read(all => [{ length => 65535 }]);
	$s->h2_rst($drain, 8);
	my (@ids, @headers);
	for my $n (0 .. 2) {
		my $uri = $path eq '/proxy/' ? $path . ($n + 1) : $path;
		my $sid = $s->new_stream({ headers => [
			{ name => ':method', value => 'GET', mode => 0 },
			{ name => ':scheme', value => 'https', mode => 0 },
			{ name => ':path', value => $uri, mode => 1 },
			{ name => ':authority', value => $authority, mode => 1 },
			defined $priority->[$n] ? { name => 'priority',
				value => $priority->[$n], mode => 2 } : ()
		] });
		push @ids, $sid;
		push @headers, @{$s->read(all => [{ sid => $sid, fin => 4 }])};
	}
	is(scalar(grep { $_->{type} eq 'HEADERS'
		&& $_->{headers}{':status'} eq '200' } @headers),
		3, "$name ready responses");
	return ($s, \@ids);
}

sub balanced {
	my ($frames, $ids, $budget, $name) = @_;
	my (%bytes, $total);
	$total = 0;
	for (grep { $_->{type} eq 'DATA' } @$frames) {
		$bytes{$_->{sid}} += $_->{length};
		$total += $_->{length};
	}
	my @bytes = sort { $a <=> $b } map { $bytes{$_} || 0 } @$ids;
	is($total, $budget, "$name credit");
	ok($bytes[0] > 0 && $bytes[-1] - $bytes[0] <= 16384,
		"$name bounded service") or diag join ' ', @bytes;
}

sub complete {
	my ($s, $ids, $frames, $name) = @_;
	$s->h2_window(3 * $size);
	push @$frames, @{$s->read(all => [
		map { { sid => $_, fin => 1 } } @$ids
	])};
	my (%data, %fin);
	for (grep { $_->{type} eq 'DATA' } @$frames) {
		$data{$_->{sid}} .= $_->{data};
		$fin{$_->{sid}}++ if $_->{flags} & 1;
	}
	ok(!(grep { !defined $data{$_} || $data{$_} ne $body } @$ids),
		"$name payload integrity");
	is(scalar(grep { ($fin{$_} || 0) == 1 } @$ids), 3,
		"$name exactly one END_STREAM per response");
}

sub http_daemon {
	my $server = IO::Socket::INET->new(
		Proto => 'tcp', LocalHost => '127.0.0.1:' . port(8086),
		Listen => 16, Reuse => 1
	) or die "Can't create origin socket: $!\n";
	local $SIG{PIPE} = 'IGNORE';
	my $read = IO::Select->new($server);
	my $write = IO::Select->new();
	my %pending;
	while (1) {
		my ($r, $w) = IO::Select->select($read, $write, undef, 1);
		for (@{$r || []}) {
			my $client = $server->accept() or next;
			my $headers = '';
			while (<$client>) {
				$headers .= $_;
				last if /^\x0d?\x0a$/;
			}
			unless ($headers =~ m!^GET /([123]) !) {
				close $client;
				next;
			}
			my $id = $1;
			my @priority = ('u=7, i', 'u=0', 'u=3, i=?0');
			my $wire = 'HTTP/1.1 200 OK' . CRLF
				. 'Connection: close' . CRLF
				. 'Priority: ' . $priority[$id - 1] . CRLF
				. 'Transfer-Encoding: chunked' . CRLF . CRLF;
			for (my $i = 0; $i < length($body); $i += 127) {
				my $chunk = substr($body, $i, 127);
				$wire .= sprintf('%x', length($chunk)) . CRLF
					. $chunk . CRLF;
			}
			$wire .= '0' . CRLF . CRLF;
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
