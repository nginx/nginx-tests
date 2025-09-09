#!/usr/bin/perl

# (C) Andrey Zelenkov
# (C) Nginx, Inc.

# Tests for geoip module.

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

    #geoip_country  %%TESTDIR%%/country.mmdb;

    geoip_country /Users/karolkostelansky/Desktop/School/cdn77_training_day/country_code_tests/country.mmdb;

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        location / {
            add_header X-Country-Code      $geoip_country_code;
        }
    }
}

EOF

my $d = $t->testdir();

$t->try_run('no inet6 support')->plan(2);

###############################################################################

my $r = http_xff('8.8.8.129');
like($r, qr/X-Country-Code: US/, 'geoip country code');

$r = http_xff('2606:4700:4700::');
like($r, qr/X-Country-Code: CA/, 'geoip ipv6 country code');

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
