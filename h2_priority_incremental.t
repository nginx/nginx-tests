#!/usr/bin/perl

# Tests for sharing bandwidth between HTTP/2 incremental responses.

###############################################################################

use warnings;
use strict;

use Test::More;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;
use Test::Nginx::HTTP2;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/http http_v2/)->plan(10)
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
    }
}

EOF

$t->write_file('large', 'x' x (2**20));
$t->write_file('small', 'SEE-THIS');
$t->run();

###############################################################################

is(waiting('i', 'i', 'i'), '1 3 5 1 3 5', 'incremental waiting streams');
is(waiting('i=?1', 'i=?1', 'i=?1'), '1 3 5 1 3 5',
	'explicit incremental waiting streams');
is(waiting('i=?0', 'i=?0', 'i=?0'), '1 1 1 1 1 1',
	'non-incremental waiting streams');
is(waiting(undef, undef, undef), '1 1 1 1 1 1',
	'default waiting streams');
is(waiting('u=3, i', 'u=0, i', 'u=3, i'), '3 3 3 3 3 3',
	'urgency takes precedence over incremental sharing');
is(waiting('i', 'i=?0', 'i'), '3 3 3 3 3 3',
	'non-incremental takes precedence at the same urgency');
is(waiting_update('i', 'i', 'i'), '1 3 5 1 3 5',
	'PRIORITY_UPDATE enables incremental sharing');
is(waiting_update('i=?0', 'i=?0', 'i=?0'), '1 1 1 1 1 1',
	'PRIORITY_UPDATE keeps non-incremental sequencing');
is(queued('i', 'i'), '3 1', 'incremental stream flow control');
is(queued('i=?0', 'i=?0'), '3 1', 'non-incremental stream flow control');

###############################################################################

sub request {
	my ($path, $priority) = @_;

	return { headers => [
		{ name => ':method', value => 'GET', mode => 0 },
		{ name => ':scheme', value => 'http', mode => 0 },
		{ name => ':path', value => $path, mode => 1 },
		{ name => ':authority', value => 'localhost', mode => 1 },
		defined $priority
			? { name => 'priority', value => $priority, mode => 2 } : ()
	] };
}

sub waiting_update {
	return waiting([@_]);
}

sub waiting {
	my $update = ref $_[0];
	my @priorities = $update ? @{$_[0]} : @_;
	my $s = Test::Nginx::HTTP2->new();
	$s->h2_settings(0, 0x4 => 2**24);
	$s->read(all => [{ type => 'SETTINGS', flags => 1 }]);

	for my $i (0 .. $#priorities) {
		my $sid = $s->new_stream(request('/large',
			$update ? undef : $priorities[$i]));
		$s->read(all => [$i == 0
			? { sid => $sid, length => 2**16 - 1 }
			: { sid => $sid, fin => 0x4 }]);
	}

	if ($update) {
		$s->h2_priority_update(2 * $_ + 1, $priorities[$_])
			for (0 .. $#priorities);
	}
	my @order;
	for (1 .. 6) {
		$s->h2_window(8192);
		my $frames = $s->read(all => [{ length => 8192 }]);
		push @order, map { $_->{sid} }
			grep { $_->{type} eq 'DATA' } @$frames;
	}
	return join ' ', @order;
}

sub queued {
	my ($p1, $p2) = @_;
	my $s = Test::Nginx::HTTP2->new();
	$s->h2_settings(0, 0x4 => 0);
	$s->read(all => [{ type => 'SETTINGS', flags => 1 }]);

	for my $priority ($p1, $p2) {
		my $sid = $s->new_stream(request('/small', $priority));
		$s->read(all => [{ sid => $sid, fin => 0x4 }]);
	}

	$s->raw_write(pack('x2C2xNN', 4, 0x8, 3, 8192)
		. pack('x2C2xNN', 4, 0x8, 1, 8192));
	my $frames = $s->read(all => [{ sid => 1, fin => 1 },
		{ sid => 3, fin => 1 }]);
	return join ' ', map { $_->{sid} }
		grep { $_->{type} eq 'DATA' } @$frames;
}

