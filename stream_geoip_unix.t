#!/usr/bin/perl

# (C) Nginx, Inc.

# Tests for the stream geoip module with unix socket.

###############################################################################

use warnings;
use strict;

use Test::More;

use Socket qw/ AF_INET AF_INET6 inet_pton /;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;
use Test::Nginx::Stream qw/ stream /;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

plan(skip_all => 'win32') if $^O eq 'MSWin32';

my $t = Test::Nginx->new()->has(qw/stream stream_geoip stream_return unix/)
	->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

stream {
    %%TEST_GLOBALS_STREAM%%

    geoip_country  %%TESTDIR%%/country.mmdb;
    geoip_city     %%TESTDIR%%/city.mmdb;
    geoip_org      %%TESTDIR%%/org.mmdb;

    server {
        listen  unix:%%TESTDIR%%/unix.sock;
        return  "country_code:$geoip_country_code
                 country_code3:$geoip_country_code3
                 country_name:$geoip_country_name
                 city:$geoip_city
                 latitude:$geoip_latitude
                 dma_code:$geoip_dma_code
                 org:$geoip_org";
    }

    server {
        listen      127.0.0.1:8080;
        proxy_pass  unix:%%TESTDIR%%/unix.sock;
    }
}

EOF

$t->write_file('country.mmdb', write_mmdb('GeoLite2-Country-Test', [
	[ '81.2.69.160', { country => { iso_code => 'GB',
		names => { en => 'United Kingdom' } } } ],
]));

$t->write_file('city.mmdb', write_mmdb('GeoLite2-City-Test', [
	[ '81.2.69.160', {
		city => { names => { en => 'London' } },
		location => { latitude => mmdb_double(51.5142),
			metro_code => mmdb_uint32(826) },
	} ],
]));

$t->write_file('org.mmdb', write_mmdb('GeoLite2-ASN-Test', [
	[ '81.2.69.160', { autonomous_system_organization => 'Nginx' } ],
]));

$t->try_run('mmdb not supported')->plan(7);

###############################################################################

my %data = stream('127.0.0.1:' . port(8080))->read() =~ /(\w+):(.*)/g;

is($data{country_code}, '', 'geoip unix country code');
is($data{country_code3}, '', 'geoip unix country code 3');
is($data{country_name}, '', 'geoip unix country name');
is($data{city}, '', 'geoip unix city');
is($data{latitude}, '', 'geoip unix latitude');
is($data{dma_code}, '', 'geoip unix dma code');
is($data{org}, '', 'geoip unix org');

###############################################################################

sub mmdb_double { bless { v => $_[0] }, 'mmdb_double' }
sub mmdb_float  { bless { v => $_[0] }, 'mmdb_float' }
sub mmdb_uint32 { bless { v => $_[0] }, 'mmdb_uint32' }
sub mmdb_int32  { bless { v => $_[0] }, 'mmdb_int32' }
sub mmdb_uint16 { bless { v => $_[0] }, 'mmdb_uint16' }
sub mmdb_uint64 { bless { v => $_[0] }, 'mmdb_uint64' }

sub mmdb_control_byte {
	my ($type, $size) = @_;
	my $t = $type <= 7 ? $type : 0;
	my $buf;

	if ($size < 29) {
		$buf = chr(($t << 5) | $size);

	} elsif ($size < 285) {
		$buf = chr(($t << 5) | 29) . chr($size - 29);

	} elsif ($size < 65821) {
		$buf = chr(($t << 5) | 30)
			. substr(pack('n', $size - 285), 0, 2);

	} else {
		$buf = chr(($t << 5) | 31)
			. substr(pack('N', $size - 65821), 1, 3);
	}

	$buf .= chr($type - 7) if $type > 7;

	return $buf;
}

sub mmdb_pack_uint {
	my ($template, $value) = @_;
	my $bytes = pack($template, $value);
	$bytes =~ s/^\x00+(?=.)//;
	return $bytes;
}

sub mmdb_pack_int32 {
	my ($value) = @_;
	return mmdb_pack_uint('N', $value) if $value >= 0;
	return pack('N', unpack('N', pack('l>', $value)));
}

sub mmdb_encode_value {
	my ($v) = @_;
	my $ref = ref $v;

	return mmdb_encode_map($v) if $ref eq 'HASH';
	return mmdb_encode_array($v) if $ref eq 'ARRAY';

	if ($ref eq 'mmdb_double') {
		return mmdb_control_byte(3, 8) . pack('d>', $v->{v});
	}

	if ($ref eq 'mmdb_float') {
		return mmdb_control_byte(15, 4) . pack('f>', $v->{v});
	}

	if ($ref eq 'mmdb_uint16') {
		my $b = mmdb_pack_uint('n', $v->{v});
		return mmdb_control_byte(5, length $b) . $b;
	}

	if ($ref eq 'mmdb_uint32') {
		my $b = mmdb_pack_uint('N', $v->{v});
		return mmdb_control_byte(6, length $b) . $b;
	}

	if ($ref eq 'mmdb_int32') {
		my $b = mmdb_pack_int32($v->{v});
		return mmdb_control_byte(8, length $b) . $b;
	}

	if ($ref eq 'mmdb_uint64') {
		my $b = mmdb_pack_uint('Q>', $v->{v});
		return mmdb_control_byte(9, length $b) . $b;
	}

	die "unsupported mmdb value: $ref" if $ref;

	return mmdb_control_byte(2, length $v) . $v;
}

sub mmdb_encode_map {
	my ($h) = @_;
	my $out = mmdb_control_byte(7, scalar keys %$h);

	for my $k (sort keys %$h) {
		$out .= mmdb_control_byte(2, length $k) . $k;
		$out .= mmdb_encode_value($h->{$k});
	}

	return $out;
}

sub mmdb_encode_array {
	my ($a) = @_;
	my $out = mmdb_control_byte(11, scalar @$a);
	$out .= mmdb_encode_value($_) for @$a;
	return $out;
}

sub mmdb_ip_bits {
	my ($ip, $ip_version) = @_;

	if (($ip_version // 6) == 4) {
		return join '', map { sprintf('%08b', $_) }
			unpack('C4', inet_pton(AF_INET, $ip));
	}

	my $packed = $ip =~ /:/
		? inet_pton(AF_INET6, $ip)
		: "\x00" x 12 . inet_pton(AF_INET, $ip);

	return join '', map { sprintf('%08b', $_) } unpack('C16', $packed);
}

sub write_mmdb {
	my ($database_type, $records, $ip_version) = @_;
	$ip_version //= 6;
	my $depth = $ip_version == 4 ? 32 : 128;

	my @tree = ([undef, undef]);
	my $data = '';

	for my $r (@$records) {
		my ($ips, $value) = @$r;
		my $offset = length $data;
		$data .= mmdb_encode_value($value);

		for my $ip (ref $ips eq 'ARRAY' ? @$ips : $ips) {
			my $bits = mmdb_ip_bits($ip, $ip_version);
			my $node = 0;

			for my $i (0 .. $depth - 1) {
				my $bit = substr($bits, $i, 1) eq '1' ? 1 : 0;

				if ($i == $depth - 1) {
					$tree[$node][$bit] =
						{ offset => $offset };
					next;
				}

				if (!defined $tree[$node][$bit]) {
					push @tree, [undef, undef];
					$tree[$node][$bit] = $#tree;
				}

				$node = $tree[$node][$bit];
			}
		}
	}

	my $node_count = scalar @tree;
	my $tree_buf = '';

	for my $node (@tree) {
		for my $side (0, 1) {
			my $rec = $node->[$side];
			my $value = !defined $rec ? $node_count
				: ref $rec ? $node_count + 16 + $rec->{offset}
				: $rec;

			$tree_buf .= substr(pack('N', $value), 1, 3);
		}
	}

	my $metadata = mmdb_encode_map({
		node_count => mmdb_uint32($node_count),
		record_size => mmdb_uint16(24),
		ip_version => mmdb_uint16($ip_version),
		database_type => $database_type,
		languages => ['en'],
		binary_format_major_version => mmdb_uint16(2),
		binary_format_minor_version => mmdb_uint16(0),
		build_epoch => mmdb_uint64(time()),
		description => { en => "$database_type test database" },
	});

	return $tree_buf . ("\x00" x 16) . $data
		. "\xab\xcd\xef" . 'MaxMind.com' . $metadata;
}

###############################################################################
