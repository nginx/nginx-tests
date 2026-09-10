#!/usr/bin/perl

# (C) Sergey Kandaurov

# limit_req based tests for nginx limit_conn module.

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

my $t = Test::Nginx->new()->has(qw/http proxy limit_conn limit_req/);

$t->write_file_expand('nginx.conf', <<'EOF')->plan(10);

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    limit_req_zone   $binary_remote_addr  zone=req:1m rate=30r/m;

    limit_conn_zone  $binary_remote_addr  zone=zone:1m;
    limit_conn_zone  $binary_remote_addr  zone=zone2:1m;
    limit_conn_zone  $binary_remote_addr  zone=custom:1m;
    limit_conn_zone  $http_x_key          zone=key:1m;

    server {
        listen       127.0.0.1:8081;
        server_name  localhost;

        location /w {
            limit_req  zone=req burst=10;
        }

        location /empty {
            return 204;
        }
    }

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        location / {
            proxy_pass http://127.0.0.1:8081;
            limit_conn zone 1;
        }

        location /1 {
            limit_conn zone 1;
        }

        location /zone {
            limit_conn zone2 1;
        }

        location /unlim {
            limit_conn zone 5;
        }

        location /custom {
            proxy_pass http://127.0.0.1:8081/;
            limit_conn_log_level info;
            limit_conn_status 501;
            limit_conn custom 1;
        }

        location /key {
            proxy_pass http://127.0.0.1:8081/empty;
            limit_conn key 10;
        }
    }
}

EOF

$t->run();

###############################################################################

# charge limit_req

http_get('/w');

# same and other zones in different locations

my $s = http_get('/w', start => 1);
like(http_get('/'), qr/^HTTP\/1.. 503 /, 'rejected');
like(http_get('/1'), qr/^HTTP\/1.. 503 /, 'rejected different location');
unlike(http_get('/zone'), qr/^HTTP\/1.. 503 /, 'passed different zone');

close $s;
unlike(http_get('/1'), qr/^HTTP\/1.. 503 /, 'passed');

# custom error code and log level

$s = http_get('/custom/w', start => 1);
like(http_get('/custom'), qr/^HTTP\/1.. 501 /, 'limit_conn_status');

like($t->read_file('error.log'),
	qr/\[info\].*limiting connections by zone "custom"/,
	'limit_conn_log_level');

# limited after unlimited

$s = http_get('/w', start => 1);
like(http_get('/unlim'), qr/404 Not Found/, 'unlimited passed');
like(http_get('/'), qr/503 Service/, 'limited rejected');

# a key within the length limit is not rejected, while an overlong key is
# rejected instead of silently skipping the limit

unlike(http_key('/key', 'short'), qr/^HTTP\/1.. 503 /, 'key passed');

TODO: {
local $TODO = 'not yet';

like(http_key('/key', 'x' x 300), qr/^HTTP\/1.. 503 /, 'overlong key rejected');

}

###############################################################################

sub http_key {
	my ($uri, $key) = @_;
	return http(<<EOF);
GET $uri HTTP/1.0
Host: localhost
X-Key: $key

EOF
}

###############################################################################
