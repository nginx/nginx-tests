#!/usr/bin/perl

# (C) Andrey Zelenkov
# (C) Nitin Swami
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

use Socket qw/ $CRLF /;

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
# databases; only the database file paths change

my $mmdb_dir = $ENV{TEST_NGINX_MMDB_DIR} // './geoip';

my $has_mmdb = -f "$mmdb_dir/GeoLite2-Country-Test.mmdb"
	&& -f "$mmdb_dir/GeoLite2-City-Test.mmdb"
	&& -f "$mmdb_dir/GeoLite2-ASN-Test.mmdb";

SKIP: {
	skip 'GeoIP2 test MMDB databases not found', 22 unless $has_mmdb;

	$t->stop();

	my $t2 = Test::Nginx->new()->write_file_expand('nginx.conf', <<"EOF");

%%TEST_GLOBALS%%

daemon off;

events {
}

stream {
    %%TEST_GLOBALS_STREAM%%

    set_real_ip_from  127.0.0.1/32;

    geoip_country  $mmdb_dir/GeoLite2-Country-Test.mmdb;
    geoip_city     $mmdb_dir/GeoLite2-City-Test.mmdb;
    geoip_org      $mmdb_dir/GeoLite2-ASN-Test.mmdb;

    server {
        listen  127.0.0.1:8080 proxy_protocol;
        return  "country_code:\$geoip_country_code
                 country_code3:\$geoip_country_code3
                 country_name:\$geoip_country_name
                 area_code:\$geoip_area_code
                 city_continent_code:\$geoip_city_continent_code
                 city_country_code:\$geoip_city_country_code
                 city_country_code3:\$geoip_city_country_code3
                 city_country_name:\$geoip_city_country_name
                 latitude:\$geoip_latitude
                 longitude:\$geoip_longitude
                 region:\$geoip_region
                 region_name:\$geoip_region_name
                 city:\$geoip_city
                 postal_code:\$geoip_postal_code
                 org:\$geoip_org";
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
}

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
