#!/usr/bin/perl

# Tests for opt-in HTTP/2 fair response scheduling.

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

my $t = Test::Nginx->new()->has(qw/http http_v2 rewrite/)->plan(43);

my $conf = <<'EOF';

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    http2 on;
    http2_fair_scheduling on;

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        location /empty {
            return 200;
        }
    }

    server {
        listen       127.0.0.1:8080;
        server_name  off.local;
        http2_fair_scheduling off;
    }

    server {
        listen       127.0.0.1:8082;
        server_name  localhost;
        http2_fair_scheduling off;
    }
}

EOF

my $size = 2**20;
my $body = join '', map { sprintf '%08x', $_ } 0 .. $size / 8 - 1;
$t->write_file('large', $body);
$t->write_file_expand('nginx.conf', $conf)->run();

###############################################################################

# Exhaust the initial connection window before opening the measured streams.
# Their HEADERS prove readiness without consuming their stream windows.  Neither
# a stream window nor an absent producer can account for unequal service here.

for my $case (
	[ 'unmarked', undef, undef, undef ],
	[ 'non-incremental', ('i=?0') x 3 ],
	[ 'incremental', ('i') x 3 ],
	[ 'mixed priority', 'u=7, i', 'u=0', 'u=3, i=?0' ]
) {
	my ($name, @priority) = @$case;
	my ($s, $ids) = ready(undef, 'localhost', @priority);
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
	complete($s, $ids, \@frames, "$name completion");
}

# Repeated updates at each credit boundary must not move an urgency-zero,
# non-incremental stream ahead of the other ready streams.

my ($s, $ids) = ready(undef, 'localhost', (undef) x 3);
my @frames;
for my $n (1 .. 6) {
	$s->start_chain();
	$s->h2_priority_update($ids->[0], 'u=7, i');
	$s->h2_priority_update($ids->[1], 'u=0, i=?0');
	$s->h2_priority_update($ids->[2], 'u=7, i');
	$s->h2_window(8192);
	$s->send_chain();
	push @frames, @{$s->read(all => [{ length => 8192 }])};
}
balanced(\@frames, $ids, 49152, 'repeated PRIORITY_UPDATE');
complete($s, $ids, \@frames, 'PRIORITY_UPDATE completion');

# Policy belongs to the initial server of this connection.  A different
# :authority must not replace its inherited setting.

($s, $ids) = ready(undef, 'off.local', (undef) x 3);
$s->h2_window(192 * 1024);
my $frames = $s->read(all => [{ length => 192 * 1024 }]);
balanced($frames, $ids, 192 * 1024, 'initial server inheritance');

# Explicit off preserves ordinary non-incremental sequencing and urgency.

($s, $ids) = ready(port(8082), 'localhost', (undef) x 3);
$s->h2_window(49152);
$frames = $s->read(all => [{ length => 49152 }]);
is(join(' ', data_ids($frames)), $ids->[0], 'explicit off sequencing');

($s, $ids) = ready(port(8082), 'localhost', 'u=7', 'u=0', 'u=7');
$s->h2_window(49152);
$frames = $s->read(all => [{ length => 49152 }]);
is(join(' ', data_ids($frames)), $ids->[1], 'explicit off urgency');

# SETTINGS can make the windows of existing streams zero or negative.  Only
# the individually reopened peer may consume this connection grant.

($s, $ids) = ready(undef, 'localhost', (undef) x 3);
$s->h2_settings(0, 0x4 => 0);
$s->read(all => [{ type => 'SETTINGS' }]);
$s->start_chain();
$s->h2_window(8192, $ids->[1]);
$s->h2_window(8192);
$s->send_chain();
$frames = $s->read(all => [{ length => 8192 }]);
is(join(' ', data_ids($frames)), $ids->[1], 'blocked peers permit progress');
is(data_bytes($frames), 8192, 'blocked peers preserve connection credit');
@frames = @$frames;
$s->h2_settings(0, 0x4 => 2**24);
$s->read(all => [{ type => 'SETTINGS' }]);
$s->h2_window(192 * 1024);
$frames = $s->read(all => [{ length => 192 * 1024 }]);
balanced($frames, $ids, 192 * 1024, 'SETTINGS reopens peers');
push @frames, @$frames;
complete($s, $ids, \@frames, 'SETTINGS completion');

# Queue cancellation and another grant in one read event.  A fair stream may
# still have a posted next-turn event when its RST_STREAM arrives.

($s, $ids) = ready(undef, 'localhost', (undef) x 3);
$s->start_chain();
$s->h2_window(16384);
$s->h2_rst($ids->[0], 8);
$s->h2_window(192 * 1024);
$s->send_chain();
$frames = $s->read(all => [{ length => 208 * 1024 }]);
my %bytes = byte_counts($frames);
ok(($bytes{$ids->[1]} || 0) > 0 && ($bytes{$ids->[2]} || 0) > 0,
	'cancellation permits peer progress');
$s->h2_window(3 * $size);
$frames = $s->read(all => [map { { sid => $_, fin => 1 } } @$ids[1, 2]]);
ok(fin_count($frames, [@$ids[1, 2]]) == 2, 'cancellation peers finish');
my $empty = $s->new_stream({ path => '/empty' });
$frames = $s->read(all => [{ sid => $empty, fin => 1 }]);
ok(fin_count($frames, [$empty]) == 1, 'empty response finishes');
is(data_bytes($frames), 0, 'empty response has no payload');

# Restart without the directive to verify the default independently of the
# explicit-off server above.

undef $s;
$t->stop();
$conf =~ s/^\s*http2_fair_scheduling (?:on|off);\n//mg;
$t->write_file_expand('nginx.conf', $conf)->run();
($s, $ids) = ready(undef, 'localhost', (undef) x 3);
$s->h2_window(49152);
$frames = $s->read(all => [{ length => 49152 }]);
is(join(' ', data_ids($frames)), $ids->[0], 'default sequencing');

###############################################################################

sub request {
	my ($path, $host, $priority) = @_;
	return { headers => [
		{ name => ':method', value => 'GET', mode => 0 },
		{ name => ':scheme', value => 'http', mode => 0 },
		{ name => ':path', value => $path, mode => 1 },
		{ name => ':authority', value => $host, mode => 1 },
		defined $priority
			? { name => 'priority', value => $priority, mode => 2 } : ()
	] };
}

sub ready {
	my ($port, $host, @priority) = @_;
	my $s = Test::Nginx::HTTP2->new($port);
	$s->h2_settings(0, 0x4 => 2**24);
	$s->read(all => [{ type => 'SETTINGS' }]);
	my $drain = $s->new_stream({ path => '/large' });
	$s->read(all => [{ length => 65535 }]);
	$s->h2_rst($drain, 8);
	my @ids;
	for (@priority) {
		my $sid = $s->new_stream(request('/large', $host, $_));
		$s->read(all => [{ sid => $sid, fin => 4 }]);
		push @ids, $sid;
	}
	return ($s, \@ids);
}

sub byte_counts {
	my ($frames) = @_;
	my %bytes;
	$bytes{$_->{sid}} += $_->{length}
		for grep { $_->{type} eq 'DATA' } @$frames;
	return %bytes;
}

sub data_bytes {
	my ($frames) = @_;
	my $sum = 0;
	$sum += $_->{length} for grep { $_->{type} eq 'DATA' } @$frames;
	return $sum;
}

sub data_ids {
	my ($frames) = @_;
	my %seen;
	return grep { !$seen{$_}++ }
		map { $_->{sid} } grep { $_->{type} eq 'DATA' } @$frames;
}

sub balanced {
	my ($frames, $ids, $budget, $name) = @_;
	my %bytes = byte_counts($frames);
	my @bytes = sort { $a <=> $b } map { $bytes{$_} || 0 } @$ids;
	is(data_bytes($frames), $budget, "$name credit");
	ok($bytes[0] > 0 && $bytes[-1] - $bytes[0] <= 16384,
		"$name bounded service") or diag join ' ', @bytes;
}

sub fin_count {
	my ($frames, $ids) = @_;
	my %fin;
	$fin{$_->{sid}}++ for grep { $_->{flags} & 1
		&& ($_->{type} eq 'DATA' || $_->{type} eq 'HEADERS') } @$frames;
	return scalar grep { ($fin{$_} || 0) == 1 } @$ids;
}

sub complete {
	my ($s, $ids, $frames, $name) = @_;
	$s->h2_window(3 * $size);
	push @$frames, @{$s->read(all => [
		map { { sid => $_, fin => 1 } } @$ids
	])};
	my %data;
	$data{$_->{sid}} .= $_->{data}
		for grep { $_->{type} eq 'DATA' } @$frames;
	ok(!(grep { !defined $data{$_} || $data{$_} ne $body } @$ids),
		"$name payload integrity");
	is(fin_count($frames, $ids), scalar @$ids, "$name END_STREAM");
}

###############################################################################
