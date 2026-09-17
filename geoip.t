#!/usr/bin/perl

# (C) Andrey Zelenkov
# (C) Nitin Swami
# (C) Nginx, Inc.

# Tests for geoip module.
#
# The geoip module supports both the legacy GeoIP (libGeoIP, *.dat) and
# the MaxMind DB (libmaxminddb, *.mmdb) database formats through the same
# "geoip_country"/"geoip_city"/"geoip_org" directives and "$geoip_*"
# variables; the format is auto-detected per database file.

###############################################################################

use warnings;
use strict;

use Test::More;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/http http_geoip/)
	->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    geoip_proxy    127.0.0.1/32;

    geoip_country  %%TESTDIR%%/country.dat;
    geoip_city     %%TESTDIR%%/city.dat;
    geoip_org      %%TESTDIR%%/org.dat;

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        location / {
            add_header X-Country-Code      $geoip_country_code;
            add_header X-Country-Code3     $geoip_country_code3;
            add_header X-Country-Name      $geoip_country_name;

            add_header X-Area-Code         $geoip_area_code;
            add_header X-C-Continent-Code  $geoip_city_continent_code;
            add_header X-C-Country-Code    $geoip_city_country_code;
            add_header X-C-Country-Code3   $geoip_city_country_code3;
            add_header X-C-Country-Name    $geoip_city_country_name;
            add_header X-Dma-Code          $geoip_dma_code;
            add_header X-Latitude          $geoip_latitude;
            add_header X-Longitude         $geoip_longitude;
            add_header X-Region            $geoip_region;
            add_header X-Region-Name       $geoip_region_name;
            add_header X-City              $geoip_city;
            add_header X-Postal-Code       $geoip_postal_code;

            add_header X-Org               $geoip_org;
        }
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
$t->write_file('index.html', '');
$t->try_run('no inet6 support')->plan(21 + 27 + 2);

###############################################################################

my $r = http_xff('10.0.0.1');
like($r, qr/X-Country-Code: RU/, 'geoip country code');
like($r, qr/X-Country-Code3: RUS/, 'geoip country code 3');
like($r, qr/X-Country-Name: Russian Federation/, 'geoip country name');

like($r, qr/X-Area-Code: 0/, 'geoip area code');
like($r, qr/X-C-Continent-Code: EU/, 'geoip city continent code');
like($r, qr/X-C-Country-Code: RU/, 'geoip city country code');
like($r, qr/X-C-Country-Code3: RUS/, 'geoip city country code 3');
like($r, qr/X-C-Country-Name: Russian Federation/, 'geoip city country name');
like($r, qr/X-Dma-Code: 0/, 'geoip dma code');
like($r, qr/X-Latitude: 55.7543/, 'geoip latitude');
like($r, qr/X-Longitude: 37.6202/, 'geoip longitude');
like($r, qr/X-Region: 48/, 'geoip region');
like($r, qr/X-Region-Name: Moscow City/, 'geoip region name');
like($r, qr/X-City: Moscow/, 'geoip city');
like($r, qr/X-Postal-Code: 119034/, 'geoip postal code');

like($r, qr/X-Org: Nginx/, 'geoip org');

like(http_xff('::ffff:10.0.0.1'), qr/X-Org: Nginx/, 'geoip ipv6 ipv4-mapped');
like(http_xff('::ffff:10.0.0.1'), qr/X-Country-Code: RU/,
	'geoip ipv6 ipv4-mapped country code');

$r = http_xff('2001:db8::');
like($r, qr/X-Country-Code: US/, 'geoip ipv6 country code');
like($r, qr/X-Country-Code3: USA/, 'geoip ipv6 country code 3');
like($r, qr/X-Country-Name: United States/, 'geoip ipv6 country name');

###############################################################################

# the same directives and variables also work with MaxMind DB (mmdb)
# databases; only the database file paths change

my $mmdb_dir = $ENV{TEST_NGINX_MMDB_DIR} // './geoip';

my $has_mmdb = -f "$mmdb_dir/GeoLite2-Country-Test.mmdb"
	&& -f "$mmdb_dir/GeoLite2-City-Test.mmdb"
	&& -f "$mmdb_dir/GeoLite2-ASN-Test.mmdb";

SKIP: {
	skip 'GeoIP2 test MMDB databases not found', 29 unless $has_mmdb;

	$t->stop();

	my $t2 = Test::Nginx->new()->write_file_expand('nginx.conf', <<"EOF");

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    geoip_proxy            127.0.0.1/32;
    geoip_proxy_recursive  on;

    geoip_country  $mmdb_dir/GeoLite2-Country-Test.mmdb;
    geoip_city     $mmdb_dir/GeoLite2-City-Test.mmdb;
    geoip_org      $mmdb_dir/GeoLite2-ASN-Test.mmdb;

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        location / {
            add_header X-Country-Code      \$geoip_country_code;
            add_header X-Country-Code3     \$geoip_country_code3;
            add_header X-Country-Name      \$geoip_country_name;

            add_header X-Area-Code         \$geoip_area_code;
            add_header X-C-Continent-Code  \$geoip_city_continent_code;
            add_header X-C-Country-Code    \$geoip_city_country_code;
            add_header X-C-Country-Code3   \$geoip_city_country_code3;
            add_header X-C-Country-Name    \$geoip_city_country_name;
            add_header X-Dma-Code          \$geoip_dma_code;
            add_header X-Latitude          \$geoip_latitude;
            add_header X-Longitude         \$geoip_longitude;
            add_header X-Region            \$geoip_region;
            add_header X-Region-Name       \$geoip_region_name;
            add_header X-City              \$geoip_city;
            add_header X-Postal-Code       \$geoip_postal_code;

            add_header X-Org               \$geoip_org;

            return 200 "ok";
        }
    }
}

EOF

	$t2->run();

	# country code lookup via XFF (81.2.69.160 -> GB in GeoLite2-Country)

	$r = http_xff('81.2.69.160');
	like($r, qr/X-Country-Code: GB/, 'geoip mmdb country code');
	like($r, qr/X-Country-Code3: GBR/, 'geoip mmdb country code3');
	like($r, qr/X-Country-Name: United Kingdom/, 'geoip mmdb country name');

	# city variables (81.2.69.160 -> London in GeoLite2-City)

	like($r, qr/X-C-Continent-Code: EU/, 'geoip mmdb city continent code');
	like($r, qr/X-C-Country-Code: GB/, 'geoip mmdb city country code');
	like($r, qr/X-C-Country-Code3: GBR/, 'geoip mmdb city country code3');
	like($r, qr/X-C-Country-Name: United Kingdom/,
		'geoip mmdb city country name');
	like($r, qr/X-City: London/, 'geoip mmdb city');
	like($r, qr/X-Region: ENG/, 'geoip mmdb region');
	like($r, qr/X-Region-Name: England/, 'geoip mmdb region name');
	like($r, qr/X-Latitude: 51.5142/, 'geoip mmdb latitude');
	like($r, qr/X-Longitude: -0.0931/, 'geoip mmdb longitude');

	# org lookup (1.128.0.0 -> "Telstra Pty Ltd" in GeoLite2-ASN)

	$r = http_xff('1.128.0.0');
	like($r, qr/X-Org: Telstra Pty Ltd/, 'geoip mmdb org');

	# second IP: US city with postal code, dma code, subdivision

	$r = http_xff('216.160.83.56');
	like($r, qr/X-Country-Code: US/, 'geoip mmdb country code US');
	like($r, qr/X-Country-Code3: USA/, 'geoip mmdb country code3 US');
	like($r, qr/X-City: Milton/, 'geoip mmdb city US');
	like($r, qr/X-Postal-Code: 98354/, 'geoip mmdb postal code');
	like($r, qr/X-Dma-Code: 819/, 'geoip mmdb dma code');
	like($r, qr/X-Region: WA/, 'geoip mmdb region US');

	# area_code has no MaxMind DB equivalent, so it's always not_found and
	# add_header omits headers with empty values

	$r = http_xff('81.2.69.160');
	unlike($r, qr/X-Area-Code/, 'geoip mmdb area code always empty');

	# not-found IP (private/RFC1918 address not in database)

	$r = http_xff('10.0.0.1');
	unlike($r, qr/X-Country-Code:/, 'geoip mmdb private ip - no country code');
	unlike($r, qr/X-City:/, 'geoip mmdb private ip - no city');

	# proxy recursive XFF resolution - multi-hop chain, last hop untrusted

	$r = http_xff('81.2.69.160, 10.0.0.1');
	unlike($r, qr/X-Country-Code:/, 'geoip mmdb xff recursive - untrusted hop');

	# multiple variables in a single request - all resolve together

	$r = http_xff('81.2.69.160');
	like($r, qr/X-Country-Code: GB.*X-City: London/s,
		'geoip mmdb multiple variables in single request');

	# IPv6 support: native IPv6 and IPv4-mapped IPv6 addresses

	$r = http_xff('2001:218::');
	like($r, qr/X-Country-Code: JP/, 'geoip mmdb ipv6 country code');
	like($r, qr/X-Country-Name: Japan/, 'geoip mmdb ipv6 country name');

	like(http_xff('::ffff:81.2.69.160'), qr/X-City: London/,
		'geoip mmdb ipv6 ipv4-mapped');

	$t2->stop();
}

###############################################################################

sub http_xff {
	my ($xff) = @_;
	return http(<<EOF);
GET / HTTP/1.0
Host: localhost
X-Forwarded-For: $xff

EOF
}

sub pack_node {
	substr pack('V', shift), 0, 3;
}

sub pack_org {
	pack('V', shift);
}

###############################################################################

