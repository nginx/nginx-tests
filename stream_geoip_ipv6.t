#!/usr/bin/perl

# (C) Nginx, Inc.

# Tests for the stream geoip module using the legacy IPv6 database editions.

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
	->has(qw/stream_realip unix/);

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
                 city_country_code:$geoip_city_country_code
                 city:$geoip_city
                 region:$geoip_region
                 postal_code:$geoip_postal_code
                 latitude:$geoip_latitude
                 longitude:$geoip_longitude
                 org:$geoip_org";
    }

    server {
        listen  unix:%%TESTDIR%%/unix.sock;
        return  "country_code:$geoip_country_code
                 city:$geoip_city
                 region_name:$geoip_region_name
                 org:$geoip_org";
    }

    server {
        listen      127.0.0.1:8081;
        proxy_pass  unix:%%TESTDIR%%/unix.sock;
    }
}

EOF

$t->write_file('country.dat', country_db('2001:db8::', 185));

$t->write_file('city.dat', legacy_db('2001:db8::', 3, 30,
	chr(185) . pack('Z*', 48) . pack('Z*', 'Moscow')
		. pack('Z*', 119034)
		. pack_node(int((55.7543 + 180) * 10000))
		. pack_node(int((37.6202 + 180) * 10000))
		. chr(0) x 3,
	chr(185) . pack('Z*', '') . pack('Z*', '') . pack('Z*', '')
		. pack_node(int((10.0 + 180) * 10000))
		. pack_node(int((20.0 + 180) * 10000))
		. chr(0) x 3));

$t->write_file('org.dat',
	legacy_db('2001:db8::', 4, 23, pack('Z*', 'Nginx')));

$t->try_run('no legacy geoip support')->plan(18);

###############################################################################

my %data = stream_pp('2001:db8::') =~ /(\w+):(.*)/g;

is($data{country_code}, 'RU', 'geoip ipv6 country code');
is($data{country_code3}, 'RUS', 'geoip ipv6 country code 3');
is($data{country_name}, 'Russian Federation', 'geoip ipv6 country name');

is($data{city_country_code}, 'RU', 'geoip ipv6 city country code');
is($data{city}, 'Moscow', 'geoip ipv6 city');
is($data{region}, 48, 'geoip ipv6 region');
is($data{postal_code}, 119034, 'geoip ipv6 postal code');
is($data{latitude}, 55.7543, 'geoip ipv6 latitude');
is($data{longitude}, 37.6202, 'geoip ipv6 longitude');

is($data{org}, 'Nginx', 'geoip ipv6 org');

%data = stream_pp('2001:db8::1') =~ /(\w+):(.*)/g;
is($data{city}, '', 'geoip ipv6 filler city');
is($data{region}, '', 'geoip ipv6 filler region');
is($data{postal_code}, '', 'geoip ipv6 filler postal code');
is($data{org}, '', 'geoip ipv6 unknown org');

%data = stream('127.0.0.1:' . port(8081))->read() =~ /(\w+):(.*)/g;

isnt($data{country_code}, 'RU', 'geoip ipv6 unix country code');
isnt($data{city}, 'Moscow', 'geoip ipv6 unix city');
is($data{region_name}, '', 'geoip ipv6 unix region name');
isnt($data{org}, 'Nginx', 'geoip ipv6 unix org');

###############################################################################

sub stream_pp {
	my ($ip) = @_;
	return stream('127.0.0.1:' . port(8080))
		->io("PROXY TCP6 $ip 127.0.0.1 8080 8080${CRLF}");
}

###############################################################################

sub legacy_db {
	my ($ip, $rlen, $type, $record, $filler) = @_;

	my $bits = join '', map { sprintf('%08b', $_) }
		unpack('C16', inet_pton(AF_INET6, $ip));

	my $pack = $rlen == 3 ? \&pack_node : \&pack_org;
	my $data = '';

	$filler = '' unless defined $filler;

	for my $i (0 .. 127) {
		my $next = $i == 127 ? 129 + length($filler) : $i + 1;

		$data .= substr($bits, $i, 1)
			? $pack->(128) . $pack->($next)
			: $pack->($next) . $pack->(128);
	}

	$data .= chr(42);
	$data .= $filler;
	$data .= $record;
	$data .= chr(0xFF) x 3;
	$data .= chr($type);
	$data .= pack_node(128);

	return $data;
}

sub country_db {
	my ($ip, $index) = @_;

	my $bits = join '', map { sprintf('%08b', $_) }
		unpack('C16', inet_pton(AF_INET6, $ip));

	my $data = '';

	for my $i (0 .. 127) {
		my $next = $i == 127 ? 0xffff00 + $index : $i + 1;

		$data .= substr($bits, $i, 1)
			? pack_node(0xffff00) . pack_node($next)
			: pack_node($next) . pack_node(0xffff00);
	}

	$data .= chr(0x00) x 3;
	$data .= chr(0xFF) x 3;
	$data .= chr(12);

	return $data;
}

sub pack_node {
	substr pack('V', shift), 0, 3;
}

sub pack_org {
	pack('V', shift);
}

###############################################################################
