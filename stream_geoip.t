#!/usr/bin/perl

# (C) Nginx, Inc.

# Tests for stream geoip module.
#
# The geoip module supports both the legacy GeoIP (libGeoIP, *.dat) and
# the MaxMind DB (libmaxminddb, *.mmdb) database formats through the same
# "geoip_country"/"geoip_city"/"geoip_org" directives and "$geoip_*"
# variables; the format is auto-detected per database file.

###############################################################################

use warnings;
use strict;

use Test::More;

use Socket qw/ $CRLF AF_INET AF_INET6 inet_pton /;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;
use Test::Nginx::Stream qw/ stream /;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/stream stream_geoip stream_return/)
	->has('stream_realip');

$t->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

stream {
    %%TEST_GLOBALS_STREAM%%

    set_real_ip_from  127.0.0.1/32;

    geoip_country  %%TESTDIR%%/country.dat;
    geoip_city     %%TESTDIR%%/city.dat;
    geoip_org      %%TESTDIR%%/org.dat;

    server {
        listen  127.0.0.1:8080 proxy_protocol;
        return  "country_code:$geoip_country_code
                 country_code3:$geoip_country_code3
                 country_name:$geoip_country_name

                 area_code:$geoip_area_code
                 city_continent_code:$geoip_city_continent_code
                 city_country_code:$geoip_city_country_code
                 city_country_code3:$geoip_city_country_code3
                 city_country_name:$geoip_city_country_name
                 dma_code:$geoip_dma_code
                 latitude:$geoip_latitude
                 longitude:$geoip_longitude
                 region:$geoip_region
                 region_name:$geoip_region_name
                 city:$geoip_city
                 postal_code:$geoip_postal_code

                 org:$geoip_org";
    }
}

EOF

my $d = $t->testdir();

# country database:
#
# "10.0.0.1","10.0.0.1","RU","Russian Federation"
# "2001:db8::","2001:db8::","US","United States"

my $data = '';

for my $i (0 .. 156) {
	# skip to offset 32 if 1st bit set in ipv6 address wins
	$data .= pack_node($i + 1) . pack_node(32), next if $i == 2;
	# otherwise default to RU
	$data .= pack_node(0xffffb9) . pack_node(0xffff00), next if $i == 31;
	# continue checking bits set in ipv6 address
	$data .= pack_node(0xffff00) . pack_node($i + 1), next
		if grep $_ == $i, (44, 49, 50, 52, 53, 55, 56, 57);
	# last bit set in ipv6 address
	$data .= pack_node(0xffffe1) . pack_node(0xffff00), next if $i == 156;
	$data .= pack_node($i + 1) . pack_node(0xffff00);
}

$data .= chr(0x00) x 3;
$data .= chr(0xFF) x 3;
$data .= chr(12);

$t->write_file('country.dat', $data);

# city database:
#
# "167772161","167772161","RU","48","Moscow","119034","55.7543",37.6202",,

$data = '';

for my $i (0 .. 31) {
	$data .= pack_node(32) . pack_node($i + 1), next if $i == 4 or $i == 6;
	$data .= pack_node(32) . pack_node($i + 2), next if $i == 31;
	$data .= pack_node($i + 1) . pack_node(32);
}

$data .= chr(42);
$data .= chr(185);
$data .= pack('Z*', 48);
$data .= pack('Z*', 'Moscow');
$data .= pack('Z*', 119034);
$data .= pack_node(int((55.7543 + 180) * 10000));
$data .= pack_node(int((37.6202 + 180) * 10000));
$data .= chr(0) x 3;
$data .= chr(0xFF) x 3;
$data .= chr(2);
$data .= pack_node(32);

$t->write_file('city.dat', $data);

# organization database:
#
# "167772161","167772161","Nginx"

$data = '';

for my $i (0 .. 31) {
	$data .= pack_org(32) . pack_org($i + 1), next if $i == 4 or $i == 6;
	$data .= pack_org(32) . pack_org($i + 2), next if $i == 31;
	$data .= pack_org($i + 1) . pack_org(32);
}

$data .= chr(42);
$data .= pack('Z*', 'Nginx');
$data .= chr(0xFF) x 3;
$data .= chr(5);
$data .= pack_node(32);

$t->write_file('org.dat', $data);
$t->try_run('no inet6 support')->plan(21 + 20 + 2);

###############################################################################

my %data = stream_pp('10.0.0.1') =~ /(\w+):(.*)/g;
is($data{country_code}, 'RU', 'geoip country code');
is($data{country_code3}, 'RUS', 'geoip country code 3');
is($data{country_name}, 'Russian Federation', 'geoip country name');

is($data{area_code}, 0, 'geoip area code');
is($data{city_continent_code}, 'EU', 'geoip city continent code');
is($data{city_country_code}, 'RU', 'geoip city country code');
is($data{city_country_code3}, 'RUS', 'geoip city country code 3');
is($data{city_country_name}, 'Russian Federation', 'geoip city country name');
is($data{dma_code}, 0, 'geoip dma code');
is($data{latitude}, 55.7543, 'geoip latitude');
is($data{longitude}, 37.6202, 'geoip longitude');
is($data{region}, 48, 'geoip region');
is($data{region_name}, 'Moscow City', 'geoip region name');
is($data{city}, 'Moscow', 'geoip city');
is($data{postal_code}, 119034, 'geoip postal code');

is($data{org}, 'Nginx', 'geoip org');

like(stream_pp('::ffff:10.0.0.1'), qr/org:Nginx/, 'geoip ipv6 ipv4-mapped');

%data = stream_pp('::ffff:10.0.0.1') =~ /(\w+):(.*)/g;
is($data{country_code}, 'RU', 'geoip ipv6 ipv4-mapped country code');

%data = stream_pp('2001:db8::') =~ /(\w+):(.*)/g;
is($data{country_code}, 'US', 'geoip ipv6 country code');
is($data{country_code3}, 'USA', 'geoip ipv6 country code 3');
is($data{country_name}, 'United States', 'geoip ipv6 country name');

###############################################################################

# the same directives and variables also work with MaxMind DB (mmdb)
# databases; only the database file paths change; the tiny test databases
# below are built directly here, mirroring pack_node()/pack_org() above for
# the legacy format - see https://maxmind.github.io/MaxMind-DB/ for the spec

$t->stop();

my $t2 = Test::Nginx->new();

$t2->write_file('country.mmdb', write_mmdb('GeoLite2-Country-Test', [
	[ ['81.2.69.160', '::ffff:81.2.69.160'],
		{ country => { iso_code => 'GB',
			names => { en => 'United Kingdom' } } } ],
	[ '216.160.83.56', { country => { iso_code => 'US' } } ],
	[ '2001:218::',
		{ country => { iso_code => 'JP', names => { en => 'Japan' } } } ],
]));

$t2->write_file('city.mmdb', write_mmdb('GeoLite2-City-Test', [
	[ ['81.2.69.160', '::ffff:81.2.69.160'], {
		continent => { code => 'EU' },
		country => { iso_code => 'GB', names => { en => 'United Kingdom' } },
		city => { names => { en => 'London' } },
		subdivisions => [ { iso_code => 'ENG',
			names => { en => 'England' } } ],
		location => { latitude => mmdb_double(51.5142),
			longitude => mmdb_double(-0.0931) },
	} ],
	[ '216.160.83.56', {
		country => { iso_code => 'US' },
		city => { names => { en => 'Milton' } },
		subdivisions => [ { iso_code => 'WA' } ],
		location => { latitude => mmdb_double(47.2513),
			longitude => mmdb_double(-122.3149) },
	} ],
]));

$t2->write_file('org.mmdb', write_mmdb('GeoLite2-ASN-Test', []));

$t2->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

stream {
    %%TEST_GLOBALS_STREAM%%

    set_real_ip_from  127.0.0.1/32;

    geoip_country  %%TESTDIR%%/country.mmdb;
    geoip_city     %%TESTDIR%%/city.mmdb;
    geoip_org      %%TESTDIR%%/org.mmdb;

    server {
        listen  127.0.0.1:8080 proxy_protocol;
        return  "country_code:$geoip_country_code
                 country_code3:$geoip_country_code3
                 country_name:$geoip_country_name
                 area_code:$geoip_area_code
                 city_continent_code:$geoip_city_continent_code
                 city_country_code:$geoip_city_country_code
                 city_country_code3:$geoip_city_country_code3
                 city_country_name:$geoip_city_country_name
                 latitude:$geoip_latitude
                 longitude:$geoip_longitude
                 region:$geoip_region
                 region_name:$geoip_region_name
                 city:$geoip_city
                 postal_code:$geoip_postal_code
                 org:$geoip_org";
    }
}

EOF

$t2->run();

# country code lookup via PROXY protocol (81.2.69.160 -> GB)

%data = stream_pp('81.2.69.160') =~ /(\w+):(.*)/g;
is($data{country_code}, 'GB', 'geoip mmdb country code');
is($data{country_code3}, 'GBR', 'geoip mmdb country code3');
is($data{country_name}, 'United Kingdom', 'geoip mmdb country name');

# city variables from city database

is($data{city_continent_code}, 'EU', 'geoip mmdb city continent code');
is($data{city_country_code}, 'GB', 'geoip mmdb city country code');
is($data{city_country_code3}, 'GBR', 'geoip mmdb city country code3');
is($data{city_country_name}, 'United Kingdom',
	'geoip mmdb city country name');
is($data{city}, 'London', 'geoip mmdb city');
is($data{region}, 'ENG', 'geoip mmdb region');

# area_code has no MaxMind DB equivalent, so it's always empty

is($data{area_code}, '', 'geoip mmdb area code always empty');

# second IP: US city with additional city fields

%data = stream_pp('216.160.83.56') =~ /(\w+):(.*)/g;
is($data{country_code}, 'US', 'geoip mmdb country code US');
is($data{city}, 'Milton', 'geoip mmdb city US');
is($data{region}, 'WA', 'geoip mmdb region US');
like($data{latitude}, qr/47\.2513/, 'geoip mmdb latitude');
like($data{longitude}, qr/-122\.3149/, 'geoip mmdb longitude');

# not-found IP (private address, not in database)

%data = stream_pp('10.0.0.1') =~ /(\w+):(.*)/g;
is($data{country_code}, '', 'geoip mmdb private ip - no country code');
is($data{city}, '', 'geoip mmdb private ip - no city');

# IPv6 support: native IPv6 and IPv4-mapped IPv6 addresses

%data = stream_pp('2001:218::') =~ /(\w+):(.*)/g;
is($data{country_code}, 'JP', 'geoip mmdb ipv6 country code');
is($data{country_name}, 'Japan', 'geoip mmdb ipv6 country name');

%data = stream_pp('::ffff:81.2.69.160') =~ /(\w+):(.*)/g;
is($data{city}, 'London', 'geoip mmdb ipv6 ipv4-mapped');

$t2->stop();

###############################################################################

sub stream_pp {
	my ($ip) = @_;
	my $type = ($ip =~ ':' ? 'TCP6' : 'TCP4');
	return stream('127.0.0.1:' . port(8080))
		->io("PROXY $type $ip 127.0.0.1 8080 8080${CRLF}");
}

sub pack_node {
	substr pack('V', shift), 0, 3;
}

sub pack_org {
	pack('V', shift);
}

###############################################################################

# minimal pure Perl MaxMind DB (mmdb) writer; only the map/array/string/
# double/uint32 data types and exact-match (host) routes are supported,
# which is all that's needed for these tiny test databases

sub mmdb_double { bless { v => $_[0] }, 'mmdb_double' }
sub mmdb_uint32 { bless { v => $_[0] }, 'mmdb_uint32' }
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
		$buf = chr(($t << 5) | 30) . substr(pack('n', $size - 285), 0, 2);

	} else {
		$buf = chr(($t << 5) | 31)
			. substr(pack('N', $size - 65821), 1, 3);
	}

	$buf .= chr($type - 7) if $type > 7;

	return $buf;
}

# MMDB integers use the shortest possible encoding; a zero-length payload
# means the value 0

sub mmdb_pack_uint {
	my ($template, $value) = @_;
	my $bytes = pack($template, $value);
	$bytes =~ s/^\x00+(?=.)//;
	return $bytes;
}

sub mmdb_encode_value {
	my ($v) = @_;
	my $ref = ref $v;

	return mmdb_encode_map($v) if $ref eq 'HASH';
	return mmdb_encode_array($v) if $ref eq 'ARRAY';

	if ($ref eq 'mmdb_double') {
		return mmdb_control_byte(3, 8) . pack('d>', $v->{v});
	}

	if ($ref eq 'mmdb_uint16') {
		my $b = mmdb_pack_uint('n', $v->{v});
		return mmdb_control_byte(5, length $b) . $b;
	}

	if ($ref eq 'mmdb_uint32') {
		my $b = mmdb_pack_uint('N', $v->{v});
		return mmdb_control_byte(6, length $b) . $b;
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

# converts an IPv4/IPv6 address to a 128-bit '0'/'1' string; an IPv4
# address is embedded in the lowest 32 bits, as required for an ip_version
# 6 tree

sub mmdb_ip_bits {
	my ($ip) = @_;
	my $packed = $ip =~ /:/
		? inet_pton(AF_INET6, $ip)
		: "\x00" x 12 . inet_pton(AF_INET, $ip);

	return join '', map { sprintf('%08b', $_) } unpack('C16', $packed);
}

# builds a mmdb database and returns its binary content; $records is an
# arrayref of [ $ip_or_arrayref_of_ips, \%data ] pairs, an arrayref of
# addresses inserting the same data at each of them (e.g. to alias an
# IPv4-mapped IPv6 address to its plain IPv4 counterpart)

sub write_mmdb {
	my ($database_type, $records) = @_;

	my @tree = ([undef, undef]);
	my $data = '';

	for my $r (@$records) {
		my ($ips, $value) = @$r;
		my $offset = length $data;
		$data .= mmdb_encode_value($value);

		for my $ip (ref $ips eq 'ARRAY' ? @$ips : $ips) {
			my $bits = mmdb_ip_bits($ip);
			my $node = 0;

			for my $i (0 .. 127) {
				my $bit = substr($bits, $i, 1) eq '1' ? 1 : 0;

				if ($i == 127) {
					$tree[$node][$bit] = { offset => $offset };
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
				: ref $rec eq 'HASH' ? $node_count + 16 + $rec->{offset}
				: $rec;

			$tree_buf .= substr(pack('N', $value), 1, 3);
		}
	}

	my $metadata = mmdb_encode_map({
		node_count => mmdb_uint32($node_count),
		record_size => mmdb_uint16(24),
		ip_version => mmdb_uint16(6),
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
