#!/usr/bin/perl

# (C) Nginx, Inc.

# Tests for syslog "rfc" and "msgid" parameters, configuration checks.

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

plan(skip_all => 'win32') if $^O eq 'MSWin32';

my $t = Test::Nginx->new();

###############################################################################

my $out = config_check($t, 'syslog:server=127.0.0.1:5140,rfc=rfc5424');

plan(skip_all => 'no rfc5424 syslog') if $out !~ /test is successful/;

$t->plan(17);

###############################################################################

my $srv = 'syslog:server=127.0.0.1:5140';

$out = config_check($t, "$srv,rfc=rfc3164");
like($out, qr/test is successful/i, 'rfc=rfc3164 accepted');

$out = config_check($t, "$srv,rfc=rfc5424");
like($out, qr/test is successful/i, 'rfc=rfc5424 accepted');

$out = config_check($t, "$srv,rfc=rfc9999");
like($out, qr/unknown syslog "rfc" value/, 'rfc=rfc9999 rejected');

# printable tags are allowed with rfc5424 only

$out = config_check($t, "$srv,rfc=rfc5424,tag=my-app");
like($out, qr/test is successful/i, 'rfc5424: hyphenated tag accepted');

$out = config_check($t, "$srv,rfc=rfc3164,tag=my-app");
like($out, qr/only allows alphanumeric/, 'rfc3164: hyphenated tag rejected');

$out = config_check($t, "$srv,rfc=rfc5424,tag=nginx.1");
like($out, qr/test is successful/i, 'rfc5424: dot in tag accepted');

$out = config_check($t, "$srv,rfc=rfc5424,tag=");
like($out, qr/"tag" must not be empty/, 'rfc5424: empty tag rejected');

# tag length is limited to 32 with rfc3164, to 48 with rfc5424

my $tag33 = 'a' x 33;
$out = config_check($t, "$srv,rfc=rfc5424,tag=$tag33");
like($out, qr/test is successful/i, 'rfc5424: 33-char tag accepted');

$out = config_check($t, "$srv,rfc=rfc3164,tag=$tag33");
like($out, qr/tag length exceeds 32/, 'rfc3164: 33-char tag rejected');

my $tag49 = 'a' x 49;
$out = config_check($t, "$srv,rfc=rfc5424,tag=$tag49");
like($out, qr/tag length exceeds 48/, 'rfc5424: 49-char tag rejected');

$out = config_check($t, "$srv,rfc=rfc3164,tag=$tag49");
like($out, qr/tag length exceeds 32/, 'rfc3164: 49-char tag rejected');

# msgid

$out = config_check($t, "$srv,rfc=rfc5424,msgid=MYAPP");
like($out, qr/test is successful/i, 'rfc5424: msgid accepted');

$out = config_check($t, "$srv,msgid=MYAPP");
like($out, qr/requires rfc=rfc5424/, 'msgid without rfc5424 rejected');

$out = config_check($t, "$srv,rfc=rfc5424,msgid=MY\xc3APP");
like($out, qr/printable US-ASCII/, 'msgid with non-ASCII byte rejected');

$out = config_check($t, "$srv,rfc=rfc5424,msgid=" . 'x' x 33);
like($out, qr/msgid length exceeds 32/, 'msgid 33-char rejected');

$out = config_check($t, "$srv,rfc=rfc5424,msgid=" . 'x' x 32);
like($out, qr/test is successful/i, 'msgid 32-char accepted');

$out = config_check($t, "$srv,rfc=rfc5424,msgid=");
like($out, qr/"msgid" must not be empty/, 'empty msgid rejected');

###############################################################################

sub config_check {
	my ($t, $syslog_param) = @_;

	$t->write_file_expand('nginx.conf', <<"EOF");

%%TEST_GLOBALS%%

error_log $syslog_param info;

daemon off;

events {
}

EOF

	my $testdir = $t->testdir();
	return qx{$Test::Nginx::NGINX -t -p $testdir/ -c nginx.conf -e error.log 2>&1};
}

###############################################################################
