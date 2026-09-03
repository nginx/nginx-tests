#!/usr/bin/perl

# (C) Nitin Swami
# (C) Nginx, Inc.

# Tests for ngx_http_geoip2_module (GeoIP2 / libmaxminddb).

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

my $t = Test::Nginx->new()->has(qw/http http_geoip2 realip/);

# MaxMind test MMDB databases shipped with libmaxminddb source
# These contain well-known test IPs (e.g. 81.2.69.160 → GB/Bracknell)

my $mmdb_dir = $ENV{TEST_NGINX_MMDB_DIR}
    // './geoip';

plan(skip_all => 'GeoIP2 test MMDB databases not found')
	unless -f "$mmdb_dir/GeoLite2-Country-Test.mmdb"
	    && -f "$mmdb_dir/GeoLite2-City-Test.mmdb"
	    && -f "$mmdb_dir/GeoLite2-ASN-Test.mmdb";

$t->plan(24);

$t->write_file_expand('nginx.conf', <<"EOF");

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    geoip2_country  $mmdb_dir/GeoLite2-Country-Test.mmdb;
    geoip2_city     $mmdb_dir/GeoLite2-City-Test.mmdb;
    geoip2_org      $mmdb_dir/GeoLite2-ASN-Test.mmdb;

    geoip2_proxy           127.0.0.1/32;
    geoip2_proxy_recursive on;

    server {
        listen       127.0.0.1:%%PORT_8080%%;
        server_name  localhost;

        location / {
            add_header X-Country-Code      \$geoip2_country_code;
            add_header X-Country-Code3     \$geoip2_country_code3;
            add_header X-Country-Name      \$geoip2_country_name;

            add_header X-Area-Code         \$geoip2_area_code;
            add_header X-C-Continent-Code  \$geoip2_city_continent_code;
            add_header X-C-Country-Code    \$geoip2_city_country_code;
            add_header X-C-Country-Code3   \$geoip2_city_country_code3;
            add_header X-C-Country-Name    \$geoip2_city_country_name;
            add_header X-Dma-Code          \$geoip2_dma_code;
            add_header X-Latitude          \$geoip2_latitude;
            add_header X-Longitude         \$geoip2_longitude;
            add_header X-Region            \$geoip2_region;
            add_header X-Region-Name       \$geoip2_region_name;
            add_header X-City              \$geoip2_city;
            add_header X-Postal-Code       \$geoip2_postal_code;

            add_header X-Org               \$geoip2_org;

            return 200 "ok";
        }
    }
}

EOF

$t->write_file('index.html', '');
$t->run();

###############################################################################

# Country code lookup via XFF (81.2.69.160 → GB in GeoLite2-Country.mmdb)

my $r = http_xff('81.2.69.160');
like($r, qr/X-Country-Code: GB/, 'geoip2 country code');
like($r, qr/X-Country-Code3: GBR/, 'geoip2 country code3');
like($r, qr/X-Country-Name: United Kingdom/, 'geoip2 country name');

# City variables (81.2.69.160 → London in GeoLite2-City.mmdb)

like($r, qr/X-C-Continent-Code: EU/, 'geoip2 city continent code');
like($r, qr/X-C-Country-Code: GB/, 'geoip2 city country code');
like($r, qr/X-C-Country-Code3: GBR/, 'geoip2 city country code3');
like($r, qr/X-C-Country-Name: United Kingdom/, 'geoip2 city country name');
like($r, qr/X-City: London/, 'geoip2 city');
like($r, qr/X-Region: ENG/, 'geoip2 region');
like($r, qr/X-Region-Name: England/, 'geoip2 region name');
like($r, qr/X-Latitude: 51.5142/, 'geoip2 latitude');
like($r, qr/X-Longitude: -0.0931/, 'geoip2 longitude');

# Org lookup (1.128.0.0 → "Telstra Pty Ltd" in GeoLite2-ASN.mmdb)

$r = http_xff('1.128.0.0');
like($r, qr/X-Org: Telstra Pty Ltd/, 'geoip2 org');

# Second IP: US city with postal code, DMA code, subdivision
# (216.160.83.56 → US/Milton/WA/98354/metro_code 819)

$r = http_xff('216.160.83.56');
like($r, qr/X-Country-Code: US/, 'geoip2 country code US');
like($r, qr/X-Country-Code3: USA/, 'geoip2 country code3 US');
like($r, qr/X-City: Milton/, 'geoip2 city US');
like($r, qr/X-Postal-Code: 98354/, 'geoip2 postal code');
like($r, qr/X-Dma-Code: 819/, 'geoip2 dma code');
like($r, qr/X-Region: WA/, 'geoip2 region US');

# area_code is always empty in GeoIP2
# add_header omits headers with empty values, so verify the header is absent

$r = http_xff('81.2.69.160');
unlike($r, qr/X-Area-Code/, 'geoip2 area code always empty');

# Not-found IP (private/RFC1918 address not in database)
# When IP is not found, variables are not_found and add_header skips them

$r = http_xff('10.0.0.1');
unlike($r, qr/X-Country-Code:/, 'geoip2 private ip - no country code');
unlike($r, qr/X-City:/, 'geoip2 private ip - no city');

# Proxy recursive XFF resolution — multi-hop chain
# The geoip2_proxy_recursive is on, so nginx resolves through the XFF chain
# XFF: 81.2.69.160, 10.0.0.1 — 10.0.0.1 is the last hop (not a trusted proxy)
# so the resolved IP should be 10.0.0.1 (not found)

$r = http_xff('81.2.69.160, 10.0.0.1');
unlike($r, qr/X-Country-Code:/, 'geoip2 xff recursive - untrusted hop');

# Multiple variables in a single request — all resolve together

$r = http_xff('81.2.69.160');
like($r, qr/X-Country-Code: GB.*X-City: London/s,
	'geoip2 multiple variables in single request');

###############################################################################

sub http_xff {
	my ($xff) = @_;
	return http(<<EOF);
GET / HTTP/1.0
Host: localhost
X-Forwarded-For: $xff

EOF
}

###############################################################################
