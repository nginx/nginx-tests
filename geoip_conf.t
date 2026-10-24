#!/usr/bin/perl

# (C) Nginx, Inc.

# Tests for the geoip module configuration handling.

###############################################################################

use warnings;
use strict;

use Test::More;

use Socket qw/ AF_INET AF_INET6 inet_pton /;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/http http_geoip/);

my $conf = <<'EOF';

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        location / {
            add_header X-Country-Code   $geoip_country_code;
            add_header X-Country-Code3  $geoip_country_code3;
            add_header X-Country-Name   $geoip_country_name;
            add_header X-City           $geoip_city;
            add_header X-Region-Name    $geoip_region_name;
            add_header X-Latitude       $geoip_latitude;
            add_header X-Dma-Code       $geoip_dma_code;
            add_header X-Org            $geoip_org;

            return 204;
        }
    }
}

EOF

$t->write_file_expand('nginx.conf', $conf);

my $d = $t->testdir();

$t->write_file('netspeed.dat', legacy_db(10));
$t->write_file('country.dat', legacy_db(1));
$t->write_file('city.dat', city_db(2));
$t->write_file('org.dat', org_db(5));

$t->write_file('truncated.dat', legacy_db(9));

$t->write_file('country6.dat', legacy_db(12, 128));
$t->write_file('city6.dat', city_db(30, 128));
$t->write_file('org6.dat', org_db(21, 128));

$t->write_file('corrupt.mmdb',
	("\x00" x 64) . "\xab\xcd\xef" . 'MaxMind.com' . "\xff\xff\xff");

$t->write_file('test.mmdb', write_mmdb('GeoLite2-Country-Test', [
	[ '81.2.69.160', { country => { iso_code => 'GB' } } ],
], 4));

$t->run()->plan(47);

###############################################################################

my $r = http_get('/');

like($r, qr/204 No Content/, 'no database request');

unlike($r, qr/X-Country-Code:/, 'no database country code');
unlike($r, qr/X-Country-Code3:/, 'no database country code3');
unlike($r, qr/X-Country-Name:/, 'no database country name');
unlike($r, qr/X-City:/, 'no database city');
unlike($r, qr/X-Region-Name:/, 'no database region name');
unlike($r, qr/X-Latitude:/, 'no database latitude');
unlike($r, qr/X-Dma-Code:/, 'no database dma code');
unlike($r, qr/X-Org:/, 'no database org');

###############################################################################

like(conf($t, 'geoip_proxy 127.0.0.1/32;'), qr/test is successful/,
	'geoip_proxy cidr');
like(conf($t, 'geoip_proxy 255.255.255.255;'), qr/test is successful/,
	'geoip_proxy all-ones');
like(conf($t, 'geoip_proxy 2001:db8::/32;'), qr/test is successful/,
	'geoip_proxy ipv6 cidr');
like(conf($t, 'geoip_proxy 127.0.0.1/8;'),
	qr/low address bits of 127\.0\.0\.1\/8 are meaningless/,
	'geoip_proxy meaningless bits');
like(conf($t, 'geoip_proxy bogus;'), qr/invalid network "bogus"/,
	'geoip_proxy invalid network');

like(conf($t, 'geoip_proxy 127.0.0.1/32; geoip_proxy_recursive on;'),
	qr/test is successful/, 'geoip_proxy_recursive');

like(conf($t, "geoip_country $d/nonexistent.mmdb;"),
	qr/"$d\/nonexistent\.mmdb"(\) failed| failed)/,
	'geoip_country no such file');

###############################################################################

SKIP: {
skip 'no mmdb support', 12
	unless conf($t, "geoip_country $d/corrupt.mmdb;") =~ /MMDB_open/;

like(conf($t, "geoip_country $d/corrupt.mmdb;"),
	qr/MMDB_open\("$d\/corrupt\.mmdb"\) failed/, 'mmdb corrupt country');
like(conf($t, "geoip_org $d/corrupt.mmdb;"),
	qr/MMDB_open\("$d\/corrupt\.mmdb"\) failed/, 'mmdb corrupt org');
like(conf($t, "geoip_city $d/corrupt.mmdb;"),
	qr/MMDB_open\("$d\/corrupt\.mmdb"\) failed/, 'mmdb corrupt city');

like(conf($t, "geoip_country $d;"), qr/MMDB_open\("$d"\) failed/,
	'mmdb open directory');

like(conf($t, "geoip_country $d/test.mmdb;"), qr/test is successful/,
	'mmdb country');
like(conf($t, "geoip_country $d/test.mmdb utf8;"), qr/test is successful/,
	'mmdb charset utf8');
like(conf($t, "geoip_country $d/test.mmdb koi8r;"),
	qr/invalid parameter "koi8r"/, 'mmdb charset invalid');
like(conf($t, "geoip_org $d/test.mmdb koi8r;"),
	qr/invalid parameter "koi8r"/, 'mmdb org charset invalid');
like(conf($t, "geoip_city $d/test.mmdb koi8r;"),
	qr/invalid parameter "koi8r"/, 'mmdb city charset invalid');

like(conf($t, "geoip_country $d/test.mmdb; geoip_country $d/test.mmdb;"),
	qr/"geoip_country" directive is duplicate/, 'mmdb country duplicate');
like(conf($t, "geoip_org $d/test.mmdb; geoip_org $d/test.mmdb;"),
	qr/"geoip_org" directive is duplicate/, 'mmdb org duplicate');
like(conf($t, "geoip_city $d/test.mmdb; geoip_city $d/test.mmdb;"),
	qr/"geoip_city" directive is duplicate/, 'mmdb city duplicate');

}

###############################################################################

SKIP: {
skip 'no legacy geoip support', 19
	unless conf($t, "geoip_country $d/country.dat;") =~ /test is successful/;

like(conf($t, "geoip_country $d/country.dat; geoip_country $d/country.dat;"),
	qr/"geoip_country" directive is duplicate/, 'legacy country duplicate');
like(conf($t, "geoip_org $d/org.dat; geoip_org $d/org.dat;"),
	qr/"geoip_org" directive is duplicate/, 'legacy org duplicate');
like(conf($t, "geoip_city $d/city.dat; geoip_city $d/city.dat;"),
	qr/"geoip_city" directive is duplicate/, 'legacy city duplicate');

like(conf($t, "geoip_country $d/country.dat utf8;"), qr/test is successful/,
	'legacy charset utf8');
like(conf($t, "geoip_country $d/country.dat koi8r;"),
	qr/invalid parameter "koi8r"/, 'legacy charset invalid');

like(conf($t, "geoip_org $d/org.dat utf8;"), qr/test is successful/,
	'legacy org charset utf8');
like(conf($t, "geoip_org $d/org.dat koi8r;"),
	qr/invalid parameter "koi8r"/, 'legacy org charset invalid');

like(conf($t, "geoip_city $d/city.dat utf8;"), qr/test is successful/,
	'legacy city charset utf8');
like(conf($t, "geoip_city $d/city.dat koi8r;"),
	qr/invalid parameter "koi8r"/, 'legacy city charset invalid');

like(conf($t, "geoip_country $d/truncated.dat;"),
	qr/GeoIP_open\(".*truncated\.dat"\) failed/, 'legacy open failed');
like(conf($t, "geoip_org $d/truncated.dat;"),
	qr/GeoIP_open\(".*truncated\.dat"\) failed/, 'legacy org open failed');
like(conf($t, "geoip_city $d/truncated.dat;"),
	qr/GeoIP_open\(".*truncated\.dat"\) failed/, 'legacy city open failed');

like(conf($t, "geoip_country $d/netspeed.dat;"),
	qr/invalid GeoIP database ".*netspeed\.dat" type:10/,
	'legacy country wrong edition');
like(conf($t, "geoip_org $d/netspeed.dat;"),
	qr/invalid GeoIP database ".*netspeed\.dat" type:10/,
	'legacy org wrong edition');
like(conf($t, "geoip_city $d/netspeed.dat;"),
	qr/invalid GeoIP City database ".*netspeed\.dat" type:10/,
	'legacy city wrong edition');

like(conf($t, "geoip_city $d/country.dat;"),
	qr/invalid GeoIP City database ".*country\.dat" type:1/,
	'legacy city with country database');

like(conf($t, "geoip_country $d/country6.dat;"), qr/test is successful/,
	'legacy country ipv6 edition');
like(conf($t, "geoip_org $d/org6.dat;"), qr/test is successful/,
	'legacy org ipv6 edition');
like(conf($t, "geoip_city $d/city6.dat;"), qr/test is successful/,
	'legacy city ipv6 edition');

}

###############################################################################

sub conf {
	my ($t, $directives) = @_;

	$t->write_file_expand('nginx.conf',
		$conf =~ s/(http \{)/$1\n    $directives\n/rg);

	my $out = $t->dump_config();

	return $out;
}

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
		$buf = chr(($t << 5) | 30) . substr(pack('n', $size - 285), 0, 2);

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

sub legacy_db {
	my ($type, $depth) = @_;
	my $data = '';

	$depth = 32 unless defined $depth;

	for my $i (0 .. $depth - 1) {
		$data .= pack_node($i + 1) . pack_node($depth);
	}

	$data .= chr(0x00) x 3;
	$data .= chr(0xFF) x 3;
	$data .= chr($type);

	return $data;
}

sub city_db {
	my ($type, $depth) = @_;
	my $data = '';

	$depth = 32 unless defined $depth;

	for my $i (0 .. $depth - 1) {
		$data .= pack_node($depth) . pack_node($i + 1), next
			if $depth == 32 and ($i == 4 or $i == 6);
		$data .= pack_node($depth) . pack_node($i + 2), next
			if $depth == 32 and $i == 31;
		$data .= pack_node($i + 1) . pack_node($depth);
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
	$data .= chr($type);
	$data .= pack_node($depth);

	return $data;
}

sub org_db {
	my ($type, $depth) = @_;
	my $data = '';

	$depth = 32 unless defined $depth;

	for my $i (0 .. $depth - 1) {
		$data .= pack_org($depth) . pack_org($i + 1), next
			if $depth == 32 and ($i == 4 or $i == 6);
		$data .= pack_org($depth) . pack_org($i + 2), next
			if $depth == 32 and $i == 31;
		$data .= pack_org($i + 1) . pack_org($depth);
	}

	$data .= chr(42);
	$data .= pack('Z*', 'Nginx');
	$data .= chr(0xFF) x 3;
	$data .= chr($type);
	$data .= pack_node($depth);

	return $data;
}

sub pack_node {
	substr pack('V', shift), 0, 3;
}

sub pack_org {
	pack('V', shift);
}

###############################################################################
