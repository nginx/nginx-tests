#!/usr/bin/perl

# (C) Sergey Kandaurov
# (C) Nginx, Inc.

# Tests for stream ssl module, ssl_certificate_cache directive.

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

my $t = Test::Nginx->new()
	->has(qw/stream stream_ssl openssl:1.0.2 socket_ssl_sni/)
	->has_daemon('openssl');

$t->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

stream {
    %%TEST_GLOBALS_STREAM%%

    ssl_certificate $ssl_server_name.crt;
    ssl_certificate_key $ssl_server_name.key;

    ssl_certificate_cache max=4 valid=1s;

    server {
        listen       127.0.0.1:8443 ssl;
        server_name  localhost;
    }

    server {
        listen       127.0.0.1:8443 ssl;
        server_name  4.example.com;

        ssl_certificate_cache off;
    }

    server {
        listen       127.0.0.1:8443 ssl;
        server_name  5.example.com;

        ssl_certificate_cache max=4 inactive=1s;
    }
}

EOF

my $d = $t->testdir();

$t->write_file('openssl.conf', <<EOF);
[ req ]
default_bits = 2048
encrypt_key = no
distinguished_name = req_distinguished_name
[ req_distinguished_name ]
EOF

foreach my $name ('1.example.com', '2.example.com', '3.example.com',
	'4.example.com', '5.example.com', 'dummy')
{
	system('openssl req -x509 -new '
		. "-config $d/openssl.conf -subj /CN=$name/ "
		. "-out $d/$name.crt -keyout $d/$name.key "
		. ">>$d/openssl.out 2>&1") == 0
		or die "Can't create certificate for $name: $!\n";
}

$t->try_run('no ssl_certificate_cache')->plan(13);

###############################################################################

like(get('1.example.com'), qr/CN=1.example.com/, 'certificate 1');
update($t, '1.example.com');

like(get('1.example.com'), qr/CN=1.example.com/, 'certificate 1 cached');

like(get('2.example.com'), qr/CN=2.example.com/, 'certificate 2');
like(get('3.example.com'), qr/CN=3.example.com/, 'certificate 3');

ok(!get('1.example.com'), 'certificate 1 evicted');

update($t, '2.example.com', 'dummy');
update($t, '3.example.com');

like(get('2.example.com'), qr/CN=2.example.com/, 'certificate 2 cached');
like(get('3.example.com'), qr/CN=3.example.com/, 'certificate 3 cached');

like(get('4.example.com'), qr/CN=4.example.com/, 'no cache');
update($t, '4.example.com', 'dummy');

like(get('4.example.com'), qr/CN=dummy/, 'no cache updated');

like(get('5.example.com'), qr/CN=5.example.com/, 'inactive');

select undef, undef, undef, 3.1;

like(get('2.example.com'), qr/CN=dummy/, 'certificate 2 expired');
ok(!get('3.example.com'), 'certificate 3 expired');

# eviction after inactive time

update($t, '5.example.com', 'dummy');

like(get('5.example.com'), qr/CN=dummy/, 'inactive expired');

###############################################################################

sub get {
	my ($host) = @_;
	my $s = http('', start => 1, SSL => 1, SSL_hostname => $host) or return;
	return $s->dump_peer_certificate();
}

sub update {
	my ($t, $old, $new) = @_;

	for my $ext ("crt", "key") {
		unlink "$d/$old.$ext";
		next if !defined $new;

		$t->write_file("$old.$ext", $t->read_file("$new.$ext"));
	}
}

###############################################################################
