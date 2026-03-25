#!/usr/bin/perl

# Tests for HTTP/3 CONNECT tunnel support.

###############################################################################

use warnings;
use strict;

use Test::More;

use IO::Socket::INET;
use Socket qw/ CRLF /;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;
use Test::Nginx::HTTP3;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

plan(skip_all => 'win32') if $^O eq 'MSWin32';

my $t = Test::Nginx->new()->has(qw/http http_v3 tunnel cryptx/)
	->has_daemon('openssl')->plan(5);

$t->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    ssl_certificate_key localhost.key;
    ssl_certificate localhost.crt;

    server {
        listen       127.0.0.1:%%PORT_8980_UDP%% quic;
        server_name  localhost;

        tunnel_pass  127.0.0.1:%%PORT_8081%%;
        tunnel_connect_timeout 2s;
        tunnel_read_timeout 2s;
        tunnel_send_timeout 2s;
    }

    server {
        listen       127.0.0.1:%%PORT_8981_UDP%% quic;
        server_name  localhost;

        location / {
            return 204;
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

system('openssl req -x509 -new '
	. "-config $d/openssl.conf -subj /CN=localhost/ "
	. "-out $d/localhost.crt -keyout $d/localhost.key "
	. ">>$d/openssl.out 2>&1") == 0
	or die "Can't create certificate for localhost: $!\n";

$t->run_daemon(\&tunnel_daemon, port(8081), 'h3');
$t->run();
$t->waitforsocket('127.0.0.1:' . port(8081));

###############################################################################

my ($s, $sid, $headers, $body) = h3_connect(undef,
	authority => 'ignored.example:443');
is($headers->{':status'}, '200', 'h3 CONNECT status');
like($body, qr/^READY h3 127\.0\.0\.1\x0d?\x0a$/s,
	'h3 CONNECT greeting');

$s->h3_body("hello" . CRLF, $sid, { body_more => 1 });
like(h3_data($s, $sid), qr/^h3:hello\x0d?\x0a$/s,
	'h3 CONNECT relays DATA frame');

($s, $sid, $headers) = h3_connect(undef);
is($headers->{':status'}, '400', 'h3 CONNECT requires :authority');

($s, $sid, $headers) = h3_connect(8981,
	authority => 'ignored.example:443');
is($headers->{':status'}, '400', 'h3 CONNECT rejected when tunnel disabled');

###############################################################################

sub h3_connect {
	my ($port, %args) = @_;

	my $s = defined $port ? Test::Nginx::HTTP3->new($port)
		: Test::Nginx::HTTP3->new();
	my @headers = ({ name => ':method', value => 'CONNECT', mode => 0 });

	if (defined $args{authority}) {
		push @headers, {
			name => ':authority',
			value => $args{authority},
			mode => 2
		};
	}

	my $sid = $s->new_stream({ headers => \@headers, body_more => 1 });
	my $frames = $s->read(all => [{ sid => $sid, type => 'HEADERS' }],
		wait => 2);
	my ($headers) = map { $_->{headers} } grep { $_->{type} eq 'HEADERS' } @$frames;
	my $body = '';

	if ($headers->{':status'} eq '200') {
		$body = h3_data($s, $sid);
	}

	return ($s, $sid, $headers, $body);
}

sub h3_data {
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
