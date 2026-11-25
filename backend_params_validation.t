#!/usr/bin/perl

# Tests that the parameters NGINX serializes towards a CGI-style backend
# never carry a byte that cannot appear in a field value.
#
# The parameters are copied verbatim, so a value that carries CR, LF or NUL
# reaches the backend, and a backend that re-emits that value in a response
# field turns it into a response splitting.  The invariant under test is
# deliberately policy-agnostic: whether NGINX refuses the request or
# sanitizes the value, the backend must not receive those bytes.
#
# The three protocols are covered in one file because the invariant is the
# same and only the wire format differs.  The responders are minimal and
# self-contained, so the test does not depend on an external FastCGI, SCGI
# or uWSGI implementation being installed.

###############################################################################

use warnings;
use strict;

use Test::More;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;

use IO::Socket::INET;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/http fastcgi scgi uwsgi/)->plan(12);

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

        location /fastcgi/ {
            fastcgi_pass 127.0.0.1:%%PORT_8081%%;
            fastcgi_param DOCUMENT_URI $uri;
        }

        location /scgi/ {
            scgi_pass 127.0.0.1:%%PORT_8082%%;
            scgi_param DOCUMENT_URI $uri;
        }

        location /uwsgi/ {
            uwsgi_pass 127.0.0.1:%%PORT_8083%%;
            uwsgi_param DOCUMENT_URI $uri;
        }
    }
}

EOF

$t->run_daemon(\&fastcgi_daemon);
$t->run_daemon(\&scgi_daemon);
$t->run_daemon(\&uwsgi_daemon);

$t->run()->waitforsocket('127.0.0.1:' . port(8081));
$t->waitforsocket('127.0.0.1:' . port(8082));
$t->waitforsocket('127.0.0.1:' . port(8083));

###############################################################################

# a path carrying CR and LF, decoded by $uri into the parameter value

my $injected = '/a%0d%0aInjected:%201';

for my $proto (qw/fastcgi scgi uwsgi/) {

	my $r = http_get("/$proto/clean");

	like($r, qr/^HTTP\/1\.[01] 200/, "$proto backend reached");
	like($r, qr/DOCUMENT_URI=/, "$proto backend received the parameter");

	$r = http_get("/$proto$injected");

	like($r, qr/^HTTP\/1\.[01] \d\d\d/, "$proto request answered");

	unlike($r, qr/<CR>|<LF>|<NUL>/,
		"$proto parameters carry no CR, LF or NUL");
}

###############################################################################

# the report the responders send back: one line per parameter, with the
# bytes that cannot appear in a field value spelled out

sub report {
	my ($params) = @_;

	my $out = '';

	for my $p (@$params) {
		my ($name, $value) = @$p;

		$value =~ s/\r/<CR>/g;
		$value =~ s/\n/<LF>/g;
		$value =~ s/\0/<NUL>/g;

		$out .= "$name=$value\n";
	}

	return $out;
}


sub response {
	my ($body) = @_;

	return "Status: 200 OK\r\nContent-Type: text/plain\r\n\r\n" . $body;
}

###############################################################################

sub fastcgi_daemon {
	open(STDOUT, '>&', STDERR);

	my $socket = IO::Socket::INET->new(
		Proto => 'tcp',
		LocalAddr => '127.0.0.1:' . port(8081),
		Listen => 10,
		ReuseAddr => 1,
	) or die "Can't listen on 127.0.0.1:" . port(8081) . ": $!";

	while (my $c = $socket->accept) {
		$c->autoflush(1);

		my $buf = '';
		my $get = sub {
			my ($n) = @_;
			while (length($buf) < $n) {
				my $chunk;
				my $r = sysread($c, $chunk, 65536);
				last if !defined($r) || $r == 0;
				$buf .= $chunk;
			}
			return substr($buf, 0, $n, '');
		};

		# FCGI_PARAMS records, terminated by an empty one, and FCGI_STDIN

		my $params = '';
		my ($params_done, $stdin_done) = (0, 0);

		while (1) {
			my $hdr = $get->(8);
			last if length($hdr) < 8;

			my (undef, $type, undef, $clen, $plen) = unpack('CCnnC', $hdr);

			my $content = $clen ? $get->($clen) : '';
			$get->($plen) if $plen;

			if ($type == 4) {
				$params .= $content;
				$params_done = 1 if $clen == 0;

			} elsif ($type == 5) {
				$stdin_done = 1 if $clen == 0;
			}

			last if $params_done && $stdin_done;
		}

		next unless $params_done && $stdin_done;

		my $out = response(report(parse_fastcgi_params($params)));

		print $c pack('CCnnCC', 1, 6, 1, length($out), 0, 0) . $out;
		print $c pack('CCnnCC', 1, 6, 1, 0, 0, 0);
		print $c pack('CCnnCC', 1, 3, 1, 8, 0, 0) . pack('nnC', 0, 0);

		close $c;
	}
}


# NGINX writes a FastCGI parameter as nameLen, valueLen, name, value,
# with each length in 1 or 4 bytes

sub parse_fastcgi_params {
	my ($p) = @_;

	my @params;

	while (length $p) {
		my $nl = fcgi_length(\$p);
		my $vl = fcgi_length(\$p);

		my $name = substr($p, 0, $nl, '');
		my $value = substr($p, 0, $vl, '');

		push @params, [$name, $value];
	}

	return \@params;
}


sub fcgi_length {
	my ($p) = @_;

	my $b = ord(substr($$p, 0, 1));
	substr($$p, 0, 1, '');

	if ($b & 0x80) {
		my $rest = substr($$p, 0, 3, '');
		$b = (($b & 0x7f) << 24)
			+ (ord(substr($rest, 0, 1)) << 16)
			+ (ord(substr($rest, 1, 1)) << 8)
			+ ord(substr($rest, 2, 1));
	}

	return $b;
}

###############################################################################

sub scgi_daemon {
	open(STDOUT, '>&', STDERR);

	my $socket = IO::Socket::INET->new(
		Proto => 'tcp',
		LocalAddr => '127.0.0.1:' . port(8082),
		Listen => 10,
		ReuseAddr => 1,
	) or die "Can't listen on 127.0.0.1:" . port(8082) . ": $!";

	while (my $c = $socket->accept) {
		$c->autoflush(1);

		my $buf = '';
		my $get = sub {
			my ($n) = @_;
			while (length($buf) < $n) {
				my $chunk;
				my $r = sysread($c, $chunk, 65536);
				last if !defined($r) || $r == 0;
				$buf .= $chunk;
			}
			return substr($buf, 0, $n, '');
		};

		# a netstring: "length:" + packet + ",", the packet being the
		# parameters as name NUL value NUL

		my $len = '';
		while (1) {
			my $ch = $get->(1);
			last if length($ch) == 0;
			last if $ch eq ':';
			$len .= $ch;
		}

		next unless length($len);

		my $packet = $get->($len);
		next unless length($packet) == $len;

		$get->(1);			# the trailing ","

		my @params;
		my @fields = split /\0/, $packet, -1;
		while (@fields) {
			my $name = shift @fields;
			my $value = shift @fields;
			last unless defined $value;
			push @params, [$name, $value];
		}

		print $c response(report(\@params));

		close $c;
	}
}

###############################################################################

sub uwsgi_daemon {
	open(STDOUT, '>&', STDERR);

	my $socket = IO::Socket::INET->new(
		Proto => 'tcp',
		LocalAddr => '127.0.0.1:' . port(8083),
		Listen => 10,
		ReuseAddr => 1,
	) or die "Can't listen on 127.0.0.1:" . port(8083) . ": $!";

	while (my $c = $socket->accept) {
		$c->autoflush(1);

		my $buf = '';
		my $get = sub {
			my ($n) = @_;
			while (length($buf) < $n) {
				my $chunk;
				my $r = sysread($c, $chunk, 65536);
				last if !defined($r) || $r == 0;
				$buf .= $chunk;
			}
			return substr($buf, 0, $n, '');
		};

		# a uwsgi packet: modifier, size, modifier, payload

		my $hdr = $get->(4);
		next unless length($hdr) == 4;

		my (undef, $size) = unpack('Cv', $hdr);

		my $payload = $get->($size);
		next unless length($payload) == $size;

		# a uwsgi variable: nameLen, name, valueLen, value, the lengths
		# being 16-bit little endian

		my @params;
		my $p = $payload;

		while (length $p) {
			my $nl = unpack('v', substr($p, 0, 2, ''));
			my $name = substr($p, 0, $nl, '');
			my $vl = unpack('v', substr($p, 0, 2, ''));
			my $value = substr($p, 0, $vl, '');

			push @params, [$name, $value];
		}

		print $c response(report(\@params));

		close $c;
	}
}

###############################################################################
