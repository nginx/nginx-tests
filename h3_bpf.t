#!/usr/bin/perl

# (C) Nginx, Inc.

# Tests for HTTP/3 with quic_bpf.

###############################################################################

use warnings;
use strict;

use Test::More;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;
use Test::Nginx::HTTP3;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

plan(skip_all => 'must be root') if $> != 0;

my $t = Test::Nginx->new()->has(qw/http http_v3 cryptx/)
	->has_daemon('openssl')->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

worker_processes 2;

events {
}

quic_bpf on;

http {
    %%TEST_GLOBALS_HTTP%%

    ssl_certificate_key localhost.key;
    ssl_certificate localhost.crt;

    server {
        listen       127.0.0.1:%%PORT_8980_UDP%% quic reuseport;
        server_name  localhost;

        location / {
            return 200 $pid;
        }
    }

    server {
        listen       %%PORT_8981_UDP%% quic reuseport;
        server_name  localhost;

        location / {
            return 200 $pid;
        }
    }

    server {
        listen       127.0.0.1:%%PORT_8982_UDP%% quic;
        server_name  localhost;

        location / {
            return 200 $pid;
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

$t->try_run('no quic_bpf')->plan(10);

###############################################################################

like(get(8980), qr/^\d+$/, 'reuseport group');
like(get(8981), qr/^\d+$/, 'wildcard group');

# requests started before the reload are finished after it, so the finishing
# packets carry connection id and have to be routed to the old worker
# through the connections map

my $s = Test::Nginx::HTTP3->new();
my @sid = map { start($s) } (1 .. 10);

reload($t, 2);

my (%pid, $ok);

for my $sid (@sid) {
	my $body = finish($s, $sid);
	next unless defined $body;

	$ok++;
	$pid{$body} = 1;
}

is($ok, 10, 'established connection after reload');
is(scalar keys %pid, 1, 'established connection, same worker');

# new connections must reach the new workers

my @new = map { get(8980) } (1 .. 5);

is(scalar(grep { defined && /^\d+$/ } @new), 5,
	'new connections after reload');
is(scalar(grep { defined && exists $pid{$_} } @new), 0,
	'new connections, new workers');

like(get(8981), qr/^\d+$/, 'wildcard group after reload');

# quic_bpf cannot be changed on reload

my $conf = $t->read_file('nginx.conf');
$conf =~ s/quic_bpf on;/quic_bpf off;/;
$t->write_file('nginx.conf', $conf);

reload($t, 2);

like($t->read_file('error.log'), qr/cannot change "quic_bpf" after reload/,
	'quic_bpf change on reload');
like(get(8980), qr/^\d+$/, 'request after quic_bpf change');

# listener w/o bpf group

$t->stop();

$conf =~ s/quic_bpf off;/quic_bpf on;/;
$conf =~ s/worker_processes 2;/worker_processes 1;/;
$t->write_file('nginx.conf', $conf);

$t->run();

like(get(8982), qr/^\d+$/, 'no bpf group');

###############################################################################

sub start {
	my ($s) = @_;

	return $s->new_stream({ body_more => 1, headers => [
		{ name => ':method', value => 'GET' },
		{ name => ':scheme', value => 'https' },
		{ name => ':path', value => '/' },
		{ name => ':authority', value => 'localhost' }]});
}

sub finish {
	my ($s, $sid) = @_;

	$s->h3_body('', $sid, {});

	my $frames = $s->read(all => [{ sid => $sid, fin => 1 }]);
	my ($frame) = grep { $_->{type} eq 'DATA' } @$frames;

	return $frame ? $frame->{data} : undef;
}

sub get {
	my ($port) = @_;

	my $s = Test::Nginx::HTTP3->new($port);
	return undef unless defined $s;

	my $sid = $s->new_stream();

	my $frames = $s->read(all => [{ sid => $sid, fin => 1 }]);
	my ($frame) = grep { $_->{type} eq 'DATA' } @$frames;

	return $frame ? $frame->{data} : undef;
}

sub reload {
	my ($t, $workers) = @_;

	my @m = $t->read_file('error.log') =~ /gracefully shutting down/g;

	$t->reload();

	for (1 .. 50) {
		my @n = $t->read_file('error.log') =~ /gracefully shutting down/g;
		last if @n >= @m + $workers;
		select undef, undef, undef, 0.1;
	}
}

###############################################################################
