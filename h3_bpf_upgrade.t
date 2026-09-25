#!/usr/bin/perl

# (C) Nginx, Inc.

# Tests for HTTP/3 with quic_bpf, binary upgrade.

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

plan(skip_all => 'can leave orphaned process group')
	unless $ENV{TEST_NGINX_UNSAFE};
plan(skip_all => 'must be root') if $> != 0;

my $t = Test::Nginx->new()->has(qw/http http_v3 cryptx/)
	->has_daemon('openssl')->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

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

$t->try_run('no quic_bpf')->plan(9);

###############################################################################

# requests started before upgrade are finished after the old master
# is gone, so that the finishing packets have to be routed to the old
# worker through the inherited connections map

my $s = Test::Nginx::HTTP3->new();
my @sid = map { start($s) } (1 .. 10);

my $oldbin = upgrade($t);

isnt($t->read_file('nginx.pid'), $oldbin, 'master pid changed');

# inheriting the maps is only visible in the log. so when it fails, the new
# master creates its own maps and attaches a new program to the same
# reuseport group, dropping the routing of all established connections

like($t->read_file('error.log'), qr/using inherited QUIC BPF maps/,
	'bpf maps inherited');
like(get(), qr/^\d+$/, 'new connection during upgrade');

# reload of one master must not take over the other master's slot

reload($t, $t->read_file('nginx.pid'));

unlike($t->read_file('error.log'), qr/both master entries are active/,
	'reload during binary upgrade');
like(get(), qr/^\d+$/, 'new connection after reload during upgrade');

quit($t, $oldbin);

my (%pid, $ok);

for my $sid (@sid) {
	my $body = finish($s, $sid);
	next unless defined $body;

	$ok++;
	$pid{$body} = 1;
}

is($ok, 10, 'established connection after upgrade');
is(scalar keys %pid, 1, 'established connection, same worker');

my $pid = get();
like($pid, qr/^\d+$/, 'new connection after old master exit');
ok(!exists $pid{$pid // ''}, 'new connection, new master worker');

###############################################################################

sub upgrade {
	my ($t) = @_;

	my $pid = $t->read_file('nginx.pid');

	kill 'USR2', $pid;

	for (1 .. 50) {
		last if -e "$d/nginx.pid" && -e "$d/nginx.pid.oldbin";
		select undef, undef, undef, 0.2;
	}

	return $pid;
}

sub quit {
	my ($t, $pid) = @_;

	kill 'QUIT', $pid;

	for (1 .. 50) {
		last if ! -e "$d/nginx.pid.oldbin";
		select undef, undef, undef, 0.2;
	}
}

sub reload {
	my ($t, $pid) = @_;

	my @m = $t->read_file('error.log') =~ /start worker processes/g;

	kill 'HUP', $pid;

	for (1 .. 50) {
		my @n = $t->read_file('error.log') =~ /start worker processes/g;
		last if @n > @m;
		select undef, undef, undef, 0.1;
	}
}

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
	my $s = Test::Nginx::HTTP3->new();
	my $sid = $s->new_stream();

	my $frames = $s->read(all => [{ sid => $sid, fin => 1 }]);
	my ($frame) = grep { $_->{type} eq 'DATA' } @$frames;

	return $frame ? $frame->{data} : undef;
}

###############################################################################
