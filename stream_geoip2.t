#!/usr/bin/perl

# (C) Nitin Swami
# (C) Nginx, Inc.

# Tests for ngx_stream_geoip2_module (GeoIP2 / libmaxminddb).

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

my $t = Test::Nginx->new()->has(qw/stream stream_geoip2 stream_return/)
	->has('stream_realip');

# MaxMind GeoLite2 databases

my $mmdb_dir = $ENV{TEST_NGINX_MMDB_DIR}
    // './geoip';

plan(skip_all => 'GeoIP2 test MMDB databases not found')
	unless -f "$mmdb_dir/GeoLite2-Country.mmdb"
	    && -f "$mmdb_dir/GeoLite2-City.mmdb"
	    && -f "$mmdb_dir/GeoLite2-ASN.mmdb";

$t->plan(17);

$t->write_file_expand('nginx.conf', <<"EOF");

%%TEST_GLOBALS%%

daemon off;

events {
}

stream {
    %%TEST_GLOBALS_STREAM%%

    set_real_ip_from  127.0.0.1/32;

    geoip2_country  $mmdb_dir/GeoLite2-Country-Test.mmdb;
    geoip2_city     $mmdb_dir/GeoLite2-City-Test.mmdb;
    geoip2_org      $mmdb_dir/GeoLite2-ASN-Test.mmdb;

    server {
        listen  127.0.0.1:%%PORT_8080%% proxy_protocol;
        return  "country_code:\$geoip2_country_code
                 country_code3:\$geoip2_country_code3
                 country_name:\$geoip2_country_name
                 area_code:\$geoip2_area_code
                 city_continent_code:\$geoip2_city_continent_code
                 city_country_code:\$geoip2_city_country_code
                 city_country_code3:\$geoip2_city_country_code3
                 city_country_name:\$geoip2_city_country_name
                 latitude:\$geoip2_latitude
                 longitude:\$geoip2_longitude
                 region:\$geoip2_region
                 region_name:\$geoip2_region_name
                 city:\$geoip2_city
                 postal_code:\$geoip2_postal_code
                 org:\$geoip2_org";
    }
}

EOF

$t->run();

###############################################################################

# Country code lookup via PROXY protocol
# 81.2.69.160 → GB in GeoLite2-Country.mmdb

my %data = stream_pp('81.2.69.160') =~ /(\w+):(.*)/g;
is($data{country_code}, 'GB', 'geoip2 stream country code');
is($data{country_code3}, 'GBR', 'geoip2 stream country code3');
is($data{country_name}, 'United Kingdom', 'geoip2 stream country name');

# City variables from city database

is($data{city_continent_code}, 'EU', 'geoip2 stream city continent code');
is($data{city_country_code}, 'GB', 'geoip2 stream city country code');
is($data{city_country_code3}, 'GBR', 'geoip2 stream city country code3');
is($data{city_country_name}, 'United Kingdom',
	'geoip2 stream city country name');
is($data{city}, 'London', 'geoip2 stream city');
is($data{region}, 'ENG', 'geoip2 stream region');

# area_code is always empty in GeoIP2

is($data{area_code}, '', 'geoip2 stream area code always empty');

# Second IP: US city with additional city fields
# 216.160.83.56 → US/Milton/WA in GeoLite2-City.mmdb

%data = stream_pp('216.160.83.56') =~ /(\w+):(.*)/g;
is($data{country_code}, 'US', 'geoip2 stream country code US');
is($data{city}, 'Milton', 'geoip2 stream city US');
is($data{region}, 'WA', 'geoip2 stream region US');
like($data{latitude}, qr/47\.2513/, 'geoip2 stream latitude');
like($data{longitude}, qr/-122\.3149/, 'geoip2 stream longitude');

# Not-found IP (private address, not in database)

%data = stream_pp('10.0.0.1') =~ /(\w+):(.*)/g;
is($data{country_code}, '', 'geoip2 stream private ip - no country code');
is($data{city}, '', 'geoip2 stream private ip - no city');

###############################################################################

sub stream_pp {
	my ($ip) = @_;
	my $type = ($ip =~ ':' ? 'TCP6' : 'TCP4');
	return stream('127.0.0.1:' . port(8080))
		->io("PROXY $type $ip 127.0.0.1 8080 8080${CRLF}");
}

###############################################################################
