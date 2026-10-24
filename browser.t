#!/usr/bin/perl

# (C) Vadim Zhestikov
# (C) Nginx, Inc.

# Tests for browser module, modern_browser configuration inheritance.

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

my $t = Test::Nginx->new()->has(qw/http browser/)->plan(3)
	->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    modern_browser        msie 5.0;
    modern_browser_value  modern;

    server {
        listen       127.0.0.1:8080;
        server_name  inherit;

        location / {
            add_header X-Modern $modern_browser;
        }
    }

    server {
        listen       127.0.0.1:8080;
        server_name  redefine;

        modern_browser  msie 5.0;

        location / {
            add_header X-Modern $modern_browser;
        }
    }
}

EOF

$t->write_file('index.html', '');
$t->run();

###############################################################################

my $modern = 'Mozilla/4.0 (compatible; MSIE 6.0; Windows NT 5.1)';
my $ancient = 'Mozilla/4.0 (compatible; MSIE 4.0; Windows 95)';

# a locally defined modern_browser works, and an old browser is not modern

like(get('/', 'redefine', $modern), qr/^X-Modern: modern/m,
	'modern browser redefined');
unlike(get('/', 'inherit', $ancient), qr/^X-Modern: modern/m,
	'ancient browser inherited');

# modern_browser defined in the http block is honoured when inherited

TODO: {
local $TODO = 'not yet';

like(get('/', 'inherit', $modern), qr/^X-Modern: modern/m,
	'modern browser inherited');

}

###############################################################################

sub get {
	my ($uri, $host, $ua) = @_;
	return http(<<EOF);
GET $uri HTTP/1.0
Host: $host
User-Agent: $ua

EOF
}

###############################################################################
