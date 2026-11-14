#!/usr/bin/perl

# (c) Eugene Grebenschikov

# Tests for root directive with an empty value.

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

my $t = Test::Nginx->new()->has(qw/http rewrite/);

plan skip_all => 'not yet' unless $t->has_version('1.31.9');

$t->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        location /var {
            set $empty "";
            root $empty;

            return 200 "root:$document_root:\n";
        }

        location /copy {
            if (-f "$document_root/nonexistent") {
                return 503;
            }

            set $empty "";
            root $empty;

            set $copy "$document_root";

            return 200 "root:$copy:\n";
        }

        location /root/ {
            set $empty "";
            root $empty;
        }

        location /filename/ {
            set $empty "";
            root $empty;

            return 200 "filename:$request_filename:\n";
        }
    }
}

EOF

mkdir($t->testdir() . '/root');
$t->write_file('root/index.html', 'SEE-THIS');

my $glibc = glibc_malloc($Test::Nginx::NGINX);

delete $ENV{MALLOC_PERTURB_};

$t->run()->plan(6);

###############################################################################

my $d = $t->testdir();

like(http_get('/copy'), qr/^HTTP\/1.. 200 .*root:\Q$d\E\/:/s,
    'empty root in script copy ' . $_) for 1 .. 2;

SKIP: {
skip 'no glibc malloc', 4 unless $glibc;

$t->stop();

$ENV{MALLOC_PERTURB_} = 208;

$t->run();

like(http_get('/var'), qr/root:\Q$d\E\/:/, 'document root');
like(http_get('/copy'), qr/root:\Q$d\E\/:/, 'document root evaluated twice');

like(http_get('/root/index.html'), qr/SEE-THIS/, 'uri mapped');
like(http_get('/filename/file'), qr/filename:\Q$d\E\/\/filename\/file:/,
	'request filename');
}

###############################################################################

sub glibc_malloc {
	my ($bin) = @_;

	return 0 if $^O ne 'linux';
	return 0 if $ENV{LD_PRELOAD};

	open my $fh, '<:raw', $bin or return 0;
	my $data = do { local $/; <$fh> };
	close $fh;

	return 0 if $data =~ /__[amt]san_init/;
	return 0 if $data =~ /lib(?:jemalloc|tcmalloc|mimalloc)/;

	return $data =~ /\0GLIBC_2\.\d|glibc\.malloc\.perturb/ ? 1 : 0;
}

###############################################################################
