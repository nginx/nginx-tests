#!/usr/bin/perl

# (C) Maxim Dounin

# Tests for nginx request body reading, with chunked transfer-coding.

###############################################################################

use 5.36.0;
use warnings;
use strict;

use Test::More;
use Socket qw/ CRLF /;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/http proxy rewrite/)->plan(2124);

$t->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    upstream u {
        server 127.0.0.1:8082;
        server 127.0.0.1:8080 backup;
    }

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        client_header_buffer_size 1k;

        location / {
            client_body_buffer_size 2k;
            add_header X-Body "$request_body";
            add_header X-Body-File "$request_body_file";
            proxy_pass http://127.0.0.1:8081;
        }
        location /b {
            client_body_buffer_size 2k;
            client_body_in_file_only on;
            add_header X-Body "$request_body";
            add_header X-Body-File "$request_body_file";
            proxy_pass http://127.0.0.1:8081;
        }
        location /single {
            client_body_in_single_buffer on;
            add_header X-Body "$request_body";
            add_header X-Body-File "$request_body_file";
            proxy_pass http://127.0.0.1:8081;
        }
        location /large {
            client_max_body_size 1k;
            proxy_pass http://127.0.0.1:8081;
        }
        location /discard {
            return 200 "TEST\n";
        }
        location /next {
            proxy_pass http://u/;
        }
    }

    server {
        listen       127.0.0.1:8081;
        server_name  localhost;

        location / {
            return 200 "TEST\n";
        }
    }

    server {
        listen       127.0.0.1:8082;
        server_name  localhost;

        location / {
            return 444;
        }
    }
}

EOF

$t->run();

###############################################################################

like(http_get_body('/', '0123456789'),
	qr/X-Body: 0123456789\x0d?$/ms, 'body');

like(http_get_body('/', '0123456789' x 128),
	qr/X-Body: (0123456789){128}\x0d?$/ms, 'body in two buffers');

like(http_get_body('/', '0123456789' x 512),
	qr/X-Body-File/ms, 'body in file');

like(read_body_file(http_get_body('/b', '0123456789' x 512)),
	qr/^(0123456789){512}$/s, 'body in file only');

like(http_get_body('/single', '0123456789' x 128),
	qr/X-Body: (0123456789){128}\x0d?$/ms, 'body in single buffer');

like(http_get_body('/large', '0123456789' x 128), qr/ 413 /, 'body too large');

# pipelined requests

like(http_get_body('/', '0123456789', '0123456789' x 128, '0123456789' x 512,
	'foobar'), qr/X-Body: foobar\x0d?$/ms, 'chunked body pipelined');
like(http_get_body('/', '0123456789' x 128, '0123456789' x 512, '0123456789',
	'foobar'), qr/X-Body: foobar\x0d?$/ms, 'chunked body pipelined 2');

like(http_get_body('/discard', '0123456789', '0123456789' x 128,
	'0123456789' x 512, 'foobar'), qr/(TEST.*){4}/ms,
	'chunked body discard');
like(http_get_body('/discard', '0123456789' x 128, '0123456789' x 512,
	'0123456789', 'foobar'), qr/(TEST.*){4}/ms,
	'chunked body discard 2');

# invalid chunks
use constant LF => "\x0A";
use constant CR => "\x0D";

like(
	http(
		'GET / HTTP/1.1' . CRLF
		. 'Host: localhost' . CRLF
		. 'Connection: close' . CRLF
		. 'Transfer-Encoding: chunked' . CRLF . CRLF
		. '4' . CRLF
		. 'SEE-THIS' . CRLF
		. '0' . CRLF . CRLF
	),
	qr/400 Bad/, 'runaway chunk'
);

like(
	http(
		'GET /discard HTTP/1.1' . CRLF
		. 'Host: localhost' . CRLF
		. 'Connection: close' . CRLF
		. 'Transfer-Encoding: chunked' . CRLF . CRLF
		. '4' . CRLF
		. 'SEE-THIS' . CRLF
		. '0' . CRLF . CRLF
	),
	qr/400 Bad/, 'runaway chunk discard'
);

sub check_chunk ($chunk, $okay, $msg) {
    my $rsp;
    if ($okay) {
        $rsp = qr/200 OK/;
    } else {
        $rsp = qr/400 Bad/;
    }
    like(
            http(
                    'GET /discard HTTP/1.1' . CRLF
                    . 'Host: localhost' . CRLF
                    . 'Connection: close' . CRLF
                    . 'Transfer-Encoding: chunked' . CRLF . CRLF
                    . '8' . CRLF
                    . 'SEE-THIS' . CRLF
                    . '0' . $chunk . CRLF . CRLF
            ),
            $rsp, $msg
    );
}

sub check_hdr_char ($hdr_byte, $okay, $msg) {
    my $rsp;
    if ($okay) {
        $rsp = qr/200 OK/;
    } else {
        $rsp = qr/400 Bad/;
    }
    like(
            http(
                    'GET /discard HTTP/1.1' . CRLF
                    . 'Host: localhost' . CRLF
                    # If this is LF the next line will be an empty header,
                    # which is invalid.
                    . "$hdr_byte: ignored". CRLF
                    . 'Connection: close' . CRLF . CRLF
            ),
            $rsp, 'header ' . $msg
    );
    like(
            http(
                    'GET /discard HTTP/1.1' . CRLF
                    . 'Host: localhost' . CRLF
                    . 'Transfer-Encoding: chunked' . CRLF
                    . 'Connection: close' . CRLF . CRLF
                    . '0' . CRLF
                    # If this is LF the next line will be an empty trailer,
                    # which is invalid.
                    . "$hdr_byte: ignored" . CRLF
                    . 'ignored: ignored' . CRLF . CRLF
            ),
            $rsp, 'trailer ' . $msg
    );
}

sub get_regex_for_okay($is_okay) {
    $is_okay ? qr/200 OK/ : qr/400 Bad/;
}

sub get_packed_and_hex ($value) {
    unless (wantarray) {
        die 'Must be called in list context';
    }
    my $packed_string = pack('C', $value);
    my $hex_byte = ($value > 0x20 && $value < 0x7F) ?
        $packed_string :
        sprintf '0x%02x', $value;
    return $packed_string, $hex_byte;
}

foreach my $hdr_byte (0..255) {
    my ($packed, $hex) = get_packed_and_hex($hdr_byte);
    my $okay = $hdr_byte >= 0x20 ? $hdr_byte != 0x7F : $hdr_byte == 0x9;
    my $msg = $okay ? 'good' : 'bad';
    like(
            http(
                    'GET /discard HTTP/1.1' . CRLF
                    # Use '"something' to trigger an error if this is a line feed
                    . 'Ignored: ' . $packed . '"something' . CRLF
                    . 'Connection: close' . CRLF
                    . 'Host: localhost' . CRLF . CRLF
            ),
            get_regex_for_okay($okay), $msg . ' byte in header value ' . $hex
    );
    like(
            http(
                    'GET /discard HTTP/1.1' . CRLF
                    . 'Transfer-Encoding: chunked' . CRLF
                    . 'Connection: close' . CRLF
                    . 'Host: localhost' . CRLF . CRLF
                    . '0' . CRLF
                    # Use '"something' to trigger an error if this is a line feed
                    . 'Ignored: ' . $packed . '"something' . CRLF
                    . 'Ignored-2: ignored' . CRLF . CRLF
            ),
            get_regex_for_okay($okay), $msg . ' byte in trailer value ' . $hex
    );
    like(
            http(
                    'GET /discard HTTP/1.1' . CRLF
                    . 'Transfer-Encoding: chunked' . CRLF
                    . 'Connection: close' . CRLF
                    . 'Host: localhost' . CRLF . CRLF
                    . "0;a=\"\\$packed\"" . CRLF . CRLF
            ),
            get_regex_for_okay($okay), $msg . ' byte in chunk extension value ' . $hex
    );
    like(
            http(
                    'GET /discard HTTP/1.1' . CRLF
                    . 'Transfer-Encoding: chunked' . CRLF
                    . 'Connection: close' . CRLF
                    . 'Host: localhost' . CRLF . CRLF
                    . "0;a=\"$packed\"" . CRLF . CRLF
            ),
            get_regex_for_okay($okay && $packed ne '\\' && $packed ne '"'),
            $msg . ' byte in unescaped chunk extension value ' . $hex
    );
}

my $token_chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&\'*+.^_-`|~';
for my $value (0..255) {
    my ($packed, $hex) = get_packed_and_hex($value);
    my $is_token = index($token_chars, $packed) != -1;
    my $msg = $is_token ? '' : ' not';
    check_chunk("; $packed=b", $is_token, "token parsing for byte $hex (is$msg token)");
    check_chunk("; a=b${packed}c", $is_token, "token parsing for byte $hex (is$msg token)");
    check_hdr_char($packed, $is_token, "header name parsing for byte $hex (is$msg token)");
}
check_hdr_char('', 0, 'name is empty');
foreach my $bad ( LF . CRLF, CRLF . LF, LF . LF, CR . CR, LF . CR, LF, CR ) {
    my $hex = unpack('H*', $bad);
    like(
            http(
                    'GET /discard HTTP/1.1' . CRLF
                    . 'Host: localhost' . CRLF
                    . 'Transfer-Encoding: chunked' . CRLF
                    . '0' . $bad
            ),
            qr/400 Bad/, 'bare LF in chunk encoding ' . $hex
    );
    like(
            http(
                    'GET /discard HTTP/1.1' . CRLF
                    . 'Host: localhost' . CRLF
                    . 'Transfer-Encoding: chunked' . CRLF
                    . 'Connection: close' . CRLF . CRLF
                    . '8' . $bad
                    . 'SEE-THIS' . CRLF
                    . '0' . CRLF . CRLF
            ),
            qr/400 Bad/, 'bare LF in chunk encoding (nonzero length) ' . $hex
    );
    like(
            http(
                    'GET /discard HTTP/1.1' . CRLF
                    . 'Host: localhost' . CRLF
                    . 'Transfer-Encoding: chunked' . CRLF
                    . 'Connection: close' . CRLF . CRLF
                    . '0' . CRLF
                    . 'a: b' . $bad . CRLF
            ),
            qr/400 Bad/, 'bare LF trailers'
    );
}

check_chunk('', 1, 'no ext');
check_chunk(';a=b', 1, 'good simple ext');
check_chunk(';', 0, 'no ext after semi');
check_chunk(';b', 0, 'no equal');
check_chunk(';b=', 0, 'no value');
check_chunk(' ;a=b', 1, 'bws before semi');
check_chunk(' ', 0, 'bws no ext');
foreach my $bws (' ', "\t") {
    check_chunk("$bws;a=b", 1, 'bws');
    check_chunk(";${bws}a=b", 1, 'bws');
    check_chunk(";a$bws=b", 1, 'bws');
    check_chunk(";a=${bws}b", 1, 'bws');
    check_chunk(";a=b${bws}", 0, 'bws after val');
}
check_chunk(';a="', 0, 'unterminated quote');
check_chunk(';=a', 0, 'empty name');
check_chunk(';a=', 0, 'empty value');
check_chunk(';a=""', 1, 'empty quoted value');
check_chunk(";a=\"\0\"", 0, 'bad char');
check_chunk(";a=\"\\a\"", 1, 'quoted string');
check_chunk(';a="\\""', 1, 'quoted string');
check_chunk(';a="\\"', 0, 'missing quote');
check_chunk(';a="\\"";b=c', 1, 'two good exts');

sub check_trailer ($trailer, $okay, $msg) {
    like(
            http(
                    'GET /discard HTTP/1.1' . CRLF
                    . 'Host: localhost' . CRLF
                    . 'Connection: close' . CRLF
                    . 'Transfer-Encoding: chunked' . CRLF . CRLF
                    . '8' . CRLF
                    . 'SEE-THIS' . CRLF
                    . '0' . CRLF . $trailer . CRLF . CRLF
            ),
            get_regex_for_okay($okay), $msg
    );
}

check_trailer('a: b', 1, 'good trailer');
check_trailer('\\: b', 0, 'bad char in name');
check_trailer("a: \0", 0, 'bad char in value');
check_trailer("ab", 0, 'no colon');
check_trailer(' ab: c', 0, 'leading space');
check_trailer('content-length: 10000', 0, 'content-length in trailer');
check_trailer('transfer-encoding: chunked', 0, 'transfer-encoding in trailer');
check_trailer('upgrade: chunked', 0, 'upgrade in trailer');
check_trailer('pgrade: chunked', 1, 'okay trailer');

# proxy_next_upstream

like(http_get_body('/next', '0123456789'),
	qr/X-Body: 0123456789\x0d?$/ms, 'body chunked next upstream');

# invalid Transfer-Encoding

like(http_transfer_encoding('identity'), qr/501 Not Implemented/,
	'transfer encoding identity');

like(http_transfer_encoding("chunked\nTransfer-Encoding: chunked"),
	qr/400 Bad/, 'transfer encoding repeat');

like(http_transfer_encoding('chunked, identity'), qr/501 Not Implemented/,
	'transfer encoding list');

like(http_transfer_encoding("chunked\nContent-Length: 5"), qr/400 Bad/,
	'transfer encoding with content-length');

like(http_transfer_encoding("chunked", "1.0"), qr/400 Bad/,
	'transfer encoding in HTTP/1.0 requests');

###############################################################################

sub read_body_file {
	my ($r) = @_;
	return '' unless $r =~ m/X-Body-File: (.*)/;
	open FILE, $1
		or return "$!";
	local $/;
	my $content = <FILE>;
	close FILE;
	return $content;
}

sub http_get_body {
	my $uri = shift;
	my $last = pop;
	return http( join '', (map {
		my $body = $_;
		"GET $uri HTTP/1.1" . CRLF
		. "Host: localhost" . CRLF
		. "Transfer-Encoding: chunked" . CRLF . CRLF
		. sprintf("%x", length $body) . CRLF
		. $body . CRLF
		. "0" . CRLF . CRLF
	} @_),
		"GET $uri HTTP/1.1" . CRLF
		. "Host: localhost" . CRLF
		. "Connection: close" . CRLF
		. "Transfer-Encoding: chunked" . CRLF . CRLF
		. sprintf("%x", length $last) . CRLF
		. $last . CRLF
		. "0" . CRLF . CRLF
	);
}

sub http_transfer_encoding {
	my ($encoding, $version) = @_;
	$version ||= "1.1";

	http("GET / HTTP/$version" . CRLF
		. "Host: localhost" . CRLF
		. "Connection: close" . CRLF
		. "Transfer-Encoding: $encoding" . CRLF . CRLF
		. "0" . CRLF . CRLF);
}

###############################################################################
