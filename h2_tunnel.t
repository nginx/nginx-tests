#!/usr/bin/perl

# Tests for HTTP/2 CONNECT tunnel support.

###############################################################################

use warnings;
use strict;

use Test::More;

use IO::Socket::INET;
use Socket qw/ CRLF /;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;
use Test::Nginx::HTTP2;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

plan(skip_all => 'win32') if $^O eq 'MSWin32';

my $t = Test::Nginx->new()->has(qw/http http_v2 tunnel/)->plan(6);

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

        http2 on;

        tunnel_pass  127.0.0.1:%%PORT_8081%%;
        tunnel_connect_timeout 2s;
        tunnel_read_timeout 2s;
        tunnel_send_timeout 2s;
    }

    server {
        listen       127.0.0.1:8082;
        server_name  localhost;

        http2 on;

        location / {
            return 204;
        }
    }
}

EOF

$t->run_daemon(\&tunnel_daemon, port(8081), 'h2');
$t->run();
$t->waitforsocket('127.0.0.1:' . port(8081));

###############################################################################

my ($s, $sid, $headers, $body) = h2_connect(port(8080),
	authority => 'ignored.example:443');
is($headers->{':status'}, '200', 'h2 CONNECT status');
like($body, qr/^READY h2 127\.0\.0\.1\x0d?\x0a$/s,
	'h2 CONNECT greeting');

$s->h2_body("hello" . CRLF, { body_more => 1 });
like(h2_data($s, $sid), qr/^h2:hello\x0d?\x0a$/s,
	'h2 CONNECT relays first DATA frame');

$s->h2_body("again" . CRLF);
like(h2_data($s, $sid, fin => 1), qr/^h2:again\x0d?\x0a$/s,
	'h2 CONNECT relays final DATA frame');

($s, $sid, $headers) = h2_connect(port(8080));
is($headers->{':status'}, '400', 'h2 CONNECT requires :authority');

($s, $sid, $headers) = h2_connect(port(8082),
	authority => 'ignored.example:443');
is($headers->{':status'}, '400', 'h2 CONNECT rejected when tunnel disabled');

###############################################################################

sub h2_connect {
	my ($port, %args) = @_;

	my $s = Test::Nginx::HTTP2->new($port, pure => 1);
	my @headers = ({ name => ':method', value => 'CONNECT' });

	if (defined $args{authority}) {
		push @headers, { name => ':authority', value => $args{authority} };
	}

	my $sid = $s->new_stream({
		body_more => $args{body_more} ? 1 : 0,
		headers => \@headers,
	});

	my $frames = $s->read(all => [{ sid => $sid, type => 'HEADERS' }],
		wait => 2);
	my ($headers) = map { $_->{headers} } grep { $_->{type} eq 'HEADERS' } @$frames;
	my $body = join('', map { $_->{data} } grep { $_->{type} eq 'DATA' } @$frames);

	if ($headers->{':status'} eq '200') {
		$body .= h2_data($s, $sid);
	}

	return ($s, $sid, $headers, $body);
}

sub h2_data {
	my ($s, $sid, %extra) = @_;

	my $frames = $s->read(all => [
		{ sid => $sid, type => 'DATA', defined $extra{fin} ? (fin => $extra{fin}) : () }
	], wait => 2);

	return join('', map { $_->{data} } grep { $_->{type} eq 'DATA' } @$frames);
}

sub tunnel_daemon {
	my ($port, $label) = @_;

	my $server = IO::Socket::INET->new(
		Proto => 'tcp',
		LocalAddr => '127.0.0.1',
		LocalPort => $port,
		Listen => 5,
		Reuse => 1,
	)
		or die "Can't create listening socket: $!\n";

	local $SIG{PIPE} = 'IGNORE';

	while (my $client = $server->accept()) {
		$client->autoflush(1);
		handle_tunnel_client($client, $label,
			eval { $client->peerhost() } || 'unknown');
	}
}

sub handle_tunnel_client {
	my ($client, $label, $peer) = @_;

	print $client "READY $label $peer" . CRLF;

	while (my $line = <$client>) {
		$line =~ s/\x0d?\x0a$//;
		print $client $label . ':' . $line . CRLF;
	}

	$client->close();
}

###############################################################################
