#!/usr/bin/perl

# (C) Nginx, Inc.

# Tests for the geoip module using the legacy IPv6 database editions.

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

my $t = Test::Nginx->new()->has(qw/http http_geoip proxy unix/)
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

            add_header X-C-Country-Code    $geoip_city_country_code;
            add_header X-City              $geoip_city;
            add_header X-Region            $geoip_region;
            add_header X-Postal-Code       $geoip_postal_code;
            add_header X-Latitude          $geoip_latitude;
            add_header X-Longitude         $geoip_longitude;

            add_header X-Org               $geoip_org;
        }

        location /unix {
            proxy_pass http://unix:%%TESTDIR%%/unix.sock:/;
        }
    }

    server {
        listen       unix:%%TESTDIR%%/unix.sock;
        server_name  localhost;

        location / {
            add_header X-Country-Code      $geoip_country_code;
            add_header X-City              $geoip_city;
            add_header X-Region-Name       $geoip_region_name;
            add_header X-Org               $geoip_org;

            return 204;
        }
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

$t->write_file('index.html', '');
$t->try_run('no legacy geoip support')->plan(19);

###############################################################################

my $r = http_xff('2001:db8::');

like($r, qr/X-Country-Code: RU/, 'geoip ipv6 country code');
like($r, qr/X-Country-Code3: RUS/, 'geoip ipv6 country code 3');
like($r, qr/X-Country-Name: Russian Federation/, 'geoip ipv6 country name');

like($r, qr/X-C-Country-Code: RU/, 'geoip ipv6 city country code');
like($r, qr/X-City: Moscow/, 'geoip ipv6 city');
like($r, qr/X-Region: 48/, 'geoip ipv6 region');
like($r, qr/X-Postal-Code: 119034/, 'geoip ipv6 postal code');
like($r, qr/X-Latitude: 55.7543/, 'geoip ipv6 latitude');
like($r, qr/X-Longitude: 37.6202/, 'geoip ipv6 longitude');

like($r, qr/X-Org: Nginx/, 'geoip ipv6 org');

$r = http_xff('2001:db8::1');
unlike($r, qr/X-City:/, 'geoip ipv6 filler city');
unlike($r, qr/X-Region:/, 'geoip ipv6 filler region');
unlike($r, qr/X-Postal-Code:/, 'geoip ipv6 filler postal code');
unlike($r, qr/X-Org: Nginx/, 'geoip ipv6 unknown org');

$r = http_get('/unix');

like($r, qr/204 No Content/, 'geoip ipv6 unix request');
unlike($r, qr/X-Country-Code: RU/, 'geoip ipv6 unix country code');
unlike($r, qr/X-City: Moscow/, 'geoip ipv6 unix city');
unlike($r, qr/X-Region-Name:/, 'geoip ipv6 unix region name');
unlike($r, qr/X-Org: Nginx/, 'geoip ipv6 unix org');

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
