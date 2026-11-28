#!/usr/bin/perl

# Tests that a field name or a field value which cannot appear on the wire
# is refused when the configuration is loaded, and that the framing fields
# cannot be set by hand.
#
# The invariant under test is deliberately policy-agnostic: whether nginx
# refuses the configuration or refuses the request, a response must never
# contain a field line created by the offending bytes, and a configuration
# which cannot be loaded must not quietly produce a response either.
#
# The last two cases cover Transfer-Encoding and Content-Length: they are
# used for framing, so a configuration that sets them by hand describes a
# message whose framing is decided twice.

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

my $t = Test::Nginx->new()->has(qw/http proxy/)->plan(6);

my @cases = (
	{
		name => 'a field name carrying CR and LF is refused',
		conf => 'add_header "X-Foo\r\nInjected: 1" "v";',
	},
	{
		name => 'a field name carrying a space is refused',
		conf => 'add_header "X Foo" "v";',
	},
	{
		name => 'a field value carrying CR and LF is refused',
		conf => 'add_header X-Foo "v\r\nInjected: 1";',
	},
	{
		name => 'Transfer-Encoding cannot be set by hand',
		conf => 'add_header Transfer-Encoding chunked;',
	},
	{
		name => 'Content-Length cannot be set by hand',
		conf => 'add_header Content-Length 5;',
	},
	{
		name => 'Transfer-Encoding cannot be set by hand in proxy_set_header',
		conf => 'proxy_set_header Transfer-Encoding chunked;',
	},
);

###############################################################################

for my $case (@cases) {
	$t->write_file_expand('nginx.conf', <<"CONF");

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        location / {
            $case->{conf}
            return 200 "ok";
        }
    }
}

CONF

	my $started = eval { $t->run(); 1 };

	ok(!$started, $case->{name});

	if ($started) {
		# the configuration was loaded, so this nginx has to be stopped
		# before the next case can use the same address
		$t->stop();
		unlink $t->{_testdir} . '/nginx.pid';
		select undef, undef, undef, 0.2;
	}
}

###############################################################################
