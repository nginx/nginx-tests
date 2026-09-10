#!/usr/bin/perl

# (C) Maxim Dounin
# (C) Eugene Grebenschikov
# (C) Nginx, Inc.

# Tests for proxy to ssl backend, backend certificate verification.

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

my $t = Test::Nginx->new()->has(qw/http http_ssl proxy/)
	->has_daemon('openssl')->plan(13)
	->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        location /verify {
            proxy_pass https://127.0.0.1:8081/;
            proxy_ssl_name example.com;
            proxy_ssl_verify on;
            proxy_ssl_trusted_certificate 1.example.com.crt;
        }

        location /wildcard {
            proxy_pass https://127.0.0.1:8081/;
            proxy_ssl_name foo.example.com;
            proxy_ssl_verify on;
            proxy_ssl_trusted_certificate 1.example.com.crt;
        }

        location /fail {
            proxy_pass https://127.0.0.1:8081/;
            proxy_ssl_name no.match.example.com;
            proxy_ssl_verify on;
            proxy_ssl_trusted_certificate 1.example.com.crt;
        }

        location /ipv4 {
            proxy_pass https://127.0.0.1:8081/;
            proxy_ssl_verify on;
            proxy_ssl_trusted_certificate 1.example.com.crt;
        }

        location /ipv4/fail {
            proxy_pass https://127.0.0.1:8081/;
            proxy_ssl_name 127.0.0.2;
            proxy_ssl_verify on;
            proxy_ssl_trusted_certificate 1.example.com.crt;
        }

        location /ipv6 {
            proxy_pass https://127.0.0.1:8081/;
            proxy_ssl_name [::1];
            proxy_ssl_verify on;
            proxy_ssl_trusted_certificate 1.example.com.crt;
        }

        location /ipv6/fail {
            proxy_pass https://127.0.0.1:8081/;
            proxy_ssl_name [::2];
            proxy_ssl_verify on;
            proxy_ssl_trusted_certificate 1.example.com.crt;
        }

        location /cn {
            proxy_pass https://127.0.0.1:8082/;
            proxy_ssl_name 2.example.com;
            proxy_ssl_verify on;
            proxy_ssl_trusted_certificate 2.example.com.crt;
        }

        location /cn/fail {
            proxy_pass https://127.0.0.1:8082/;
            proxy_ssl_name bad.example.com;
            proxy_ssl_verify on;
            proxy_ssl_trusted_certificate 2.example.com.crt;
        }

        location /cn/wildcard {
            proxy_pass https://127.0.0.1:8083/;
            proxy_ssl_name any.example.com;
            proxy_ssl_verify on;
            proxy_ssl_trusted_certificate 3.example.com.crt;
        }

        location /cn/ip {
            proxy_pass https://127.0.0.1:8084/;
            proxy_ssl_name 127.0.0.1;
            proxy_ssl_verify on;
            proxy_ssl_trusted_certificate 4.example.com.crt;
        }

        location /cn/ipv6 {
            proxy_pass https://127.0.0.1:8085/;
            proxy_ssl_name [::1];
            proxy_ssl_verify on;
            proxy_ssl_trusted_certificate 5.example.com.crt;
        }

        location /untrusted {
            proxy_pass https://127.0.0.1:8082/;
            proxy_ssl_verify on;
            proxy_ssl_trusted_certificate 1.example.com.crt;
            proxy_ssl_session_reuse off;
        }
    }

    server {
        listen 127.0.0.1:8081 ssl;
        server_name 1.example.com;

        ssl_certificate 1.example.com.crt;
        ssl_certificate_key 1.example.com.key;

        add_header X-Name $ssl_server_name;
    }

    server {
        listen 127.0.0.1:8082 ssl;
        server_name 2.example.com;

        ssl_certificate 2.example.com.crt;
        ssl_certificate_key 2.example.com.key;

        add_header X-Name $ssl_server_name;
    }

    server {
        listen 127.0.0.1:8083 ssl;
        server_name 3.example.com;

        ssl_certificate 3.example.com.crt;
        ssl_certificate_key 3.example.com.key;

        add_header X-Name $ssl_server_name;
    }

    server {
        listen 127.0.0.1:8084 ssl;
        server_name 4.example.com;

        ssl_certificate 4.example.com.crt;
        ssl_certificate_key 4.example.com.key;

        add_header X-Name $ssl_server_name;
    }

    server {
        listen 127.0.0.1:8085 ssl;
        server_name 5.example.com;

        ssl_certificate 5.example.com.crt;
        ssl_certificate_key 5.example.com.key;

        add_header X-Name $ssl_server_name;
    }
}

EOF

$t->write_file('openssl.1.example.com.conf', <<EOF);
[ req ]
prompt = no
default_bits = 2048
encrypt_key = no
distinguished_name = req_distinguished_name
x509_extensions = v3_req

[ req_distinguished_name ]
commonName=no.match.example.com

[ v3_req ]
subjectAltName = DNS:example.com,DNS:*.example.com,IP:127.0.0.1,IP:::1
EOF

$t->write_file('openssl.2.example.com.conf', <<EOF);
[ req ]
prompt = no
default_bits = 2048
encrypt_key = no
distinguished_name = req_distinguished_name

[ req_distinguished_name ]
commonName=2.example.com
EOF

$t->write_file('openssl.3.example.com.conf', <<EOF);
[ req ]
prompt = no
default_bits = 2048
encrypt_key = no
distinguished_name = req_distinguished_name

[ req_distinguished_name ]
commonName=*.example.com
EOF

$t->write_file('openssl.4.example.com.conf', <<EOF);
[ req ]
prompt = no
default_bits = 2048
encrypt_key = no
distinguished_name = req_distinguished_name

[ req_distinguished_name ]
commonName=127.0.0.1
EOF

$t->write_file('openssl.5.example.com.conf', <<EOF);
[ req ]
prompt = no
default_bits = 2048
encrypt_key = no
distinguished_name = req_distinguished_name

[ req_distinguished_name ]
commonName=::1
EOF

my $d = $t->testdir();

foreach my $name ('1.example.com', '2.example.com', '3.example.com',
    '4.example.com', '5.example.com')
{
	system('openssl req -x509 -new '
		. "-config $d/openssl.$name.conf "
		. "-out $d/$name.crt -keyout $d/$name.key "
		. ">>$d/openssl.out 2>&1") == 0
		or die "Can't create certificate for $name: $!\n";
}

sleep 1 if $^O eq 'MSWin32';

$t->write_file('index.html', '');

$t->run();

###############################################################################

# subjectAltName

like(http_get('/verify'), qr/200 OK/ms, 'verify');
like(http_get('/wildcard'), qr/200 OK/ms, 'verify wildcard');
like(http_get('/fail'), qr/502 Bad/ms, 'verify fail');

TODO: {
local $TODO = 'not yet' unless $t->has_version('1.31.3');

like(http_get('/ipv4'), qr/200 OK/ms, 'verify ipv4');
like(http_get('/ipv6'), qr/200 OK/ms, 'verify ipv6');

}

like(http_get('/ipv4/fail'), qr/502 Bad/ms, 'verify ipv4 fail');
like(http_get('/ipv6/fail'), qr/502 Bad/ms, 'verify ipv6 fail');

# commonName

like(http_get('/cn'), qr/200 OK/ms, 'verify cn');
like(http_get('/cn/fail'), qr/502 Bad/ms, 'verify cn fail');
like(http_get('/cn/wildcard'), qr/200 OK/ms, 'verify cn wildcard');
like(http_get('/cn/ipv4'), qr/502 Bad/ms, 'verify cn ipv4 fail');
like(http_get('/cn/ipv6'), qr/502 Bad/ms, 'verify cn ipv6 fail');

# untrusted

like(http_get('/untrusted'), qr/502 Bad/ms, 'untrusted');

###############################################################################
