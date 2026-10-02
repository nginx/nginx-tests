#!/usr/bin/perl

# Tests for Cache-Control extensions with X-Accel-Expires overrides.

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

my @controls = ('max-age=60,private', 'no-cache', 'no-store',
	'max-age=0', 's-maxage=0');
my @extensions = ('stale-while-revalidate=600', 'stale-if-error=1200',
	'stale-while-revalidate=600,stale-if-error=1200');

my $t = Test::Nginx->new()->has(qw/http proxy cache/)->plan(180);

$t->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    proxy_cache_path %%TESTDIR%%/cache keys_zone=NAME:1m;

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        proxy_cache NAME;
        proxy_cache_key $request_uri;
        proxy_cache_valid 1m;
        proxy_cache_background_update on;

        add_header X-Cache $upstream_cache_status always;

        location / {
            proxy_pass http://127.0.0.1:8081;
        }

        location /ignore/ {
            proxy_ignore_headers X-Accel-Expires;
            proxy_pass http://127.0.0.1:8081/;
        }
    }

    server {
        listen       127.0.0.1:8081;
        server_name  localhost;

        if ($http_x_error) {
            return 444;
        }

        location /before {
            add_header Cache-Control "$arg_control, $arg_extension";
            add_header X-Accel-Expires $arg_expires;
            return 200 "OK";
        }

        location /after {
            add_header X-Accel-Expires $arg_expires;
            add_header Cache-Control "$arg_control, $arg_extension";
            return 200 "OK";
        }
    }
}

EOF

$t->run();

###############################################################################

# Already expired, but still within the stale extension windows.

my $expires = time() - 10;

for my $control (@controls, 'max-age=60') {
	for my $order ('before', 'after') {
		for my $extension (@extensions) {
			my $uri = "/$order?control=$control"
				. "&extension=$extension&expires=\@$expires";
			my $test = "$control $order x-accel-expires "
				. $extension;

			like(http_get($uri), qr/200 OK.*X-Cache: MISS/s,
				"$test - populate");

			my $response = $extension =~ /^stale-if-error=/
				? get_error($uri) : http_get($uri);

			like($response, qr/200 OK.*X-Cache: STALE/s,
				"$test - stale");
		}
	}
}

# Cache-Control restrictions must still prevent caching when the override
# is missing, zero, or ignored.

for my $control (@controls) {
	for my $order ('before', 'after') {
		for my $override ('', '&expires=0', '&expires=60') {
			my $prefix = $override eq '&expires=60'
				? '/ignore' : '';
			my $uri = "$prefix/$order?control=$control"
				. '&extension=stale-while-revalidate=600'
				. $override;

			like(http_get($uri), qr/X-Cache: MISS/,
				"$uri - first request");
			like(http_get($uri), qr/X-Cache: MISS/,
				"$uri - not cached");
		}
	}
}

# With only stale-if-error, a successful upstream response is revalidated
# synchronously, rather than being served stale.

for my $control (@controls, 'max-age=60') {
	for my $order ('before', 'after') {
		my $uri = "/$order?control=$control"
			. '&extension=stale-if-error=1200'
			. "&expires=\@$expires";

		like(http_get($uri), qr/200 OK.*X-Cache: EXPIRED/s,
			"$control $order x-accel-expires - revalidate");
	}
}

# stale-if-error can outlast stale-while-revalidate without extending the
# background update window.

$expires = time() - 900;

for my $control (@controls, 'max-age=60') {
	for my $order ('before', 'after') {
		my $uri = "/$order?control=$control"
			. '&extension=stale-while-revalidate=600,'
			. 'stale-if-error=1200'
			. "&expires=\@$expires";
		my $test = "$control $order x-accel-expires - error window";

		like(http_get($uri), qr/200 OK.*X-Cache: MISS/s,
			"$test - populate");
		like(get_error($uri), qr/200 OK.*X-Cache: STALE/s,
			"$test - stale");
		like(http_get($uri), qr/200 OK.*X-Cache: EXPIRED/s,
			"$test - revalidate");
	}
}

###############################################################################

sub get_error {
	my ($uri) = @_;
	return http(<<EOF);
GET $uri HTTP/1.0
Host: localhost
X-Error: 1

EOF
}

###############################################################################
