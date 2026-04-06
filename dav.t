#!/usr/bin/perl

# (C) Maxim Dounin
# (C) Sai Krishna Kumar Reddy YADAMAKANTI

# Tests for nginx dav module.

###############################################################################

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

my $t = Test::Nginx->new()->has(qw/http dav/)->plan(96);

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

        absolute_redirect off;

        location / {
            dav_methods PUT DELETE MKCOL COPY MOVE;
        }

        location /i/ {
            alias %%TESTDIR%%/;
            dav_methods PUT DELETE MKCOL COPY MOVE;
        }

        location /full/ {
            dav_methods PUT DELETE MKCOL COPY MOVE;
            create_full_put_path on;
        }

        location /min3/ {
            dav_methods PUT DELETE MKCOL COPY MOVE;
            min_delete_depth 3;
        }

        location /min0/ {
            dav_methods PUT DELETE MKCOL COPY MOVE;
            min_delete_depth 0;
        }

        location /off/ {
        }

        location /access/ {
            dav_methods PUT DELETE MKCOL COPY MOVE;
            dav_access user:rw group:r all:r;
        }
    }
}

EOF

mkdir($t->testdir() . '/min3');
mkdir($t->testdir() . '/min0');
mkdir($t->testdir() . '/off');
mkdir($t->testdir() . '/access');

$t->run();

###############################################################################

my $r;

$r = http(<<EOF . '0123456789');
PUT /file HTTP/1.1
Host: localhost
Connection: close
Content-Length: 10

EOF

like($r, qr/201 Created.*(Content-Length|\x0d\0a0\x0d\x0a)/ms, 'put file');
is(-s $t->testdir() . '/file', 10, 'put file size');

$r = http(<<EOF);
PUT /file HTTP/1.1
Host: localhost
Connection: close
Content-Length: 0

EOF

like($r, qr/204 No Content/, 'put file again');
unlike($r, qr/Content-Length|Transfer-Encoding/, 'no length in 204');
is(-s $t->testdir() . '/file', 0, 'put file again size');

$r = http(<<EOF);
DELETE /file HTTP/1.1
Host: localhost
Connection: close
Content-Length: 0

EOF

like($r, qr/204 No Content/, 'delete file');
unlike($r, qr/Content-Length|Transfer-Encoding/, 'no length in 204');
ok(!-f $t->testdir() . '/file', 'file deleted');

$r = http(<<EOF . '0123456789' . 'extra');
PUT /file HTTP/1.1
Host: localhost
Connection: close
Content-Length: 10

EOF

like($r, qr/201 Created.*(Content-Length|\x0d\0a0\x0d\x0a)/ms,
	'put file extra data');
is(-s $t->testdir() . '/file', 10,
	'put file extra data size');

$r = http(<<EOF . '0123456789');
PUT /file%20sp HTTP/1.1
Host: localhost
Connection: close
Content-Length: 10

EOF

like($r, qr!Location: /file%20sp\x0d?$!ms, 'put file escaped');

# 201 replies contain body, response should indicate it's empty

$r = http(<<EOF);
MKCOL /test/ HTTP/1.1
Host: localhost
Connection: close

EOF

like($r, qr/201 Created.*(Content-Length|\x0d\0a0\x0d\x0a)/ms, 'mkcol');

SKIP: {
skip 'perl too old', 1 if !$^V or $^V lt v5.12.0;

like($r, qr!(?(?{ $r =~ /Location/ })Location: /test/)!, 'mkcol location');

}

$r = http(<<EOF);
COPY /test/ HTTP/1.1
Host: localhost
Destination: /test-moved/
Connection: close

EOF

like($r, qr/201 Created.*(Content-Length|\x0d\0a0\x0d\x0a)/ms, 'copy dir');

$r = http(<<EOF);
MOVE /test/ HTTP/1.1
Host: localhost
Destination: /test-moved/
Connection: close

EOF

like($r, qr/201 Created.*(Content-Length|\x0d\0a0\x0d\x0a)/ms, 'move dir');

$r = http(<<EOF);
COPY /file HTTP/1.1
Host: localhost
Destination: /file-moved%20escape
Connection: close

EOF

like($r, qr/204 No Content/, 'copy file escaped');
is(-s $t->testdir() . '/file-moved escape', 10, 'file copied unescaped');

$t->write_file('file.exist', join '', (1 .. 42));

$r = http(<<EOF);
COPY /file HTTP/1.1
Host: localhost
Destination: /file.exist
Connection: close

EOF

like($r, qr/204 No Content/, 'copy file overwrite');
is(-s $t->testdir() . '/file.exist', 10, 'target file truncated');

$r = http(<<EOF . '0123456789');
PUT /i/alias HTTP/1.1
Host: localhost
Connection: close
Content-Length: 10

EOF

like($r, qr/201 Created.*(Content-Length|\x0d\0a0\x0d\x0a)/ms, 'put alias');
like($r, qr!Location: /i/alias\x0d?$!ms, 'location alias');
is(-s $t->testdir() . '/alias', 10, 'put alias size');

# request methods with unsupported request body

$r = http(<<EOF . '0123456789');
MKCOL /test/ HTTP/1.1
Host: localhost
Connection: close
Content-Length: 10

EOF

like($r, qr/415 Unsupported/, 'mkcol body');

$r = http(<<EOF . '0123456789');
COPY /file HTTP/1.1
Host: localhost
Destination: /file.exist
Connection: close
Content-Length: 10

EOF

like($r, qr/415 Unsupported/, 'copy body');

$r = http(<<EOF . '0123456789');
DELETE /file HTTP/1.1
Host: localhost
Connection: close
Content-Length: 10

EOF

like($r, qr/415 Unsupported/, 'delete body');

my $chunked = 'a' . CRLF . '0123456789' . CRLF . '0' . CRLF . CRLF;

$r = http(<<EOF . $chunked);
MKCOL /test/ HTTP/1.1
Host: localhost
Connection: close
Transfer-Encoding: chunked

EOF

like($r, qr/415 Unsupported/, 'mkcol body chunked');

$r = http(<<EOF . $chunked);
COPY /file HTTP/1.1
Host: localhost
Destination: /file.exist
Connection: close
Transfer-Encoding: chunked

EOF

like($r, qr/415 Unsupported/, 'copy body chunked');

$r = http(<<EOF . $chunked);
DELETE /file HTTP/1.1
Host: localhost
Connection: close
Transfer-Encoding: chunked

EOF

like($r, qr/415 Unsupported/, 'delete body chunked');

# PUT edge cases

$r = http(<<EOF . '0123456789');
PUT /trailing/ HTTP/1.1
Host: localhost
Connection: close
Content-Length: 10

EOF

like($r, qr/409/, 'put to collection uri');

$r = http(<<EOF . '0123456789');
PUT /range_file HTTP/1.1
Host: localhost
Connection: close
Content-Length: 10
Content-Range: bytes 0-9/20

EOF

like($r, qr/501/, 'put with content-range');

$r = http(<<EOF . 'dated');
PUT /dated_file HTTP/1.1
Host: localhost
Connection: close
Content-Length: 5
Date: Thu, 01 Jan 2026 00:00:00 GMT

EOF

like($r, qr/201 Created/, 'put with valid date header');

$r = http(<<EOF . 'baddt');
PUT /baddate_file HTTP/1.1
Host: localhost
Connection: close
Content-Length: 5
Date: invalid-date-value

EOF

like($r, qr/201 Created/, 'put with invalid date header');

mkdir($t->testdir() . '/existdir');

$r = http(<<EOF . 'data');
PUT /existdir HTTP/1.1
Host: localhost
Connection: close
Content-Length: 4

EOF

like($r, qr/409/, 'put over existing directory');

$r = http(<<EOF . 'deep');
PUT /full/a/b/c/deep_file HTTP/1.1
Host: localhost
Connection: close
Content-Length: 4

EOF

like($r, qr/201 Created/, 'put create full path');
ok(-f $t->testdir() . '/full/a/b/c/deep_file', 'put create full path exists');

$r = http(<<EOF . 'fail');
PUT /noparent/sub/file HTTP/1.1
Host: localhost
Connection: close
Content-Length: 4

EOF

like($r, qr/(?:409|500)/, 'put without full path fails');

$r = http(<<EOF);
PUT /zerofile HTTP/1.1
Host: localhost
Connection: close
Content-Length: 0

EOF

like($r, qr/201 Created/, 'put zero-length new file');

# DELETE edge cases

$r = http(<<EOF);
DELETE /nonexistent HTTP/1.1
Host: localhost
Connection: close
Content-Length: 0

EOF

like($r, qr/404/, 'delete non-existent');

mkdir($t->testdir() . '/deldir_noslash');
$t->write_file('deldir_noslash/f', 'x');

$r = http(<<EOF);
DELETE /deldir_noslash HTTP/1.1
Host: localhost
Connection: close
Content-Length: 0

EOF

like($r, qr/409/, 'delete dir without trailing slash');

mkdir($t->testdir() . '/deldir');
$t->write_file('deldir/f1', 'x');

$r = http(<<EOF);
DELETE /deldir/ HTTP/1.1
Host: localhost
Connection: close

EOF

like($r, qr/204 No Content/, 'delete dir with trailing slash');
ok(!-d $t->testdir() . '/deldir', 'delete dir removed');

mkdir($t->testdir() . '/nested');
mkdir($t->testdir() . '/nested/sub');
$t->write_file('nested/a', 'x');
$t->write_file('nested/sub/b', 'x');

$r = http(<<EOF);
DELETE /nested/ HTTP/1.1
Host: localhost
Connection: close

EOF

like($r, qr/204 No Content/, 'delete nested directory');
ok(!-d $t->testdir() . '/nested', 'delete nested removed');

# Depth header

mkdir($t->testdir() . '/depthdir');
$t->write_file('depthdir/f', 'x');

$r = http(<<EOF);
DELETE /depthdir/ HTTP/1.1
Host: localhost
Connection: close
Depth: 0

EOF

like($r, qr/400/, 'delete dir depth 0');

$r = http(<<EOF);
DELETE /depthdir/ HTTP/1.1
Host: localhost
Connection: close
Depth: 1

EOF

like($r, qr/400/, 'delete dir depth 1');

$t->write_file('depthfile', 'x');

$r = http(<<EOF);
DELETE /depthfile HTTP/1.1
Host: localhost
Connection: close
Depth: 1

EOF

like($r, qr/400/, 'delete file depth 1');

$t->write_file('depthfile0', 'x');

$r = http(<<EOF);
DELETE /depthfile0 HTTP/1.1
Host: localhost
Connection: close
Depth: 0

EOF

like($r, qr/204 No Content/, 'delete file depth 0');

$t->write_file('depthfile_inf', 'x');

$r = http(<<EOF);
DELETE /depthfile_inf HTTP/1.1
Host: localhost
Connection: close
Depth: infinity

EOF

like($r, qr/204 No Content/, 'delete file depth infinity');

$t->write_file('baddepth', 'x');

$r = http(<<EOF);
DELETE /baddepth HTTP/1.1
Host: localhost
Connection: close
Depth: bogus

EOF

like($r, qr/400/, 'delete invalid depth header');

$t->write_file('depth2', 'x');

$r = http(<<EOF);
DELETE /depth2 HTTP/1.1
Host: localhost
Connection: close
Depth: 2

EOF

like($r, qr/400/, 'delete depth 2 invalid');

# min_delete_depth

$t->write_file('min3/shallow', 'x');

$r = http(<<EOF);
DELETE /min3/shallow HTTP/1.1
Host: localhost
Connection: close
Content-Length: 0

EOF

like($r, qr/409/, 'min_delete_depth too shallow');

mkdir($t->testdir() . '/min3/a');
mkdir($t->testdir() . '/min3/a/b');
$t->write_file('min3/a/b/deep', 'x');

$r = http(<<EOF);
DELETE /min3/a/b/deep HTTP/1.1
Host: localhost
Connection: close
Content-Length: 0

EOF

like($r, qr/204 No Content/, 'min_delete_depth deep enough');

$t->write_file('min0/top', 'x');

$r = http(<<EOF);
DELETE /min0/top HTTP/1.1
Host: localhost
Connection: close
Content-Length: 0

EOF

like($r, qr/204 No Content/, 'min_delete_depth 0');

# MKCOL edge cases

$r = http(<<EOF);
MKCOL /no_slash HTTP/1.1
Host: localhost
Connection: close

EOF

like($r, qr/409/, 'mkcol without trailing slash');

$r = http(<<EOF);
MKCOL /newcol/ HTTP/1.1
Host: localhost
Connection: close

EOF

$r = http(<<EOF);
MKCOL /newcol/ HTTP/1.1
Host: localhost
Connection: close

EOF

like($r, qr/405/, 'mkcol existing directory');

$r = http(<<EOF);
MKCOL /nonexist_parent/child/ HTTP/1.1
Host: localhost
Connection: close

EOF

like($r, qr/409/, 'mkcol missing parent');

# Destination header validation

$t->write_file('src_file', 'COPYDATA');

$r = http(<<EOF);
COPY /src_file HTTP/1.1
Host: localhost
Connection: close

EOF

like($r, qr/400/, 'copy no destination');

$r = http(<<EOF);
COPY /src_file HTTP/1.1
Host: localhost
Destination: ftp://localhost/bad_scheme
Connection: close

EOF

like($r, qr/400/, 'copy invalid destination scheme');

$r = http(<<EOF);
COPY /src_file HTTP/1.1
Host: localhost
Destination: http://otherhost/file
Connection: close

EOF

like($r, qr/400/, 'copy different host');

$r = http(<<EOF);
COPY /src_file HTTP/1.1
Host: localhost
Destination: http://localhost/full_url_copy
Connection: close

EOF

like($r, qr/20[14]/, 'copy with full url destination');

$r = http(<<EOF);
COPY /src_file HTTP/1.1
Host: localhost:8080
Destination: http://localhost:8080/port_copy
Connection: close

EOF

like($r, qr/20[14]/, 'copy with port in destination');

$r = http(<<EOF);
COPY /src_file HTTP/1.1
Host: localhost
Destination: http://localhost
Connection: close

EOF

like($r, qr/400/, 'copy destination no path after host');

$r = http(<<EOF);
MOVE /src_file HTTP/1.1
Host: localhost
Connection: close

EOF

like($r, qr/400/, 'move no destination');

# Overwrite header

$t->write_file('src_ow', 'OWDATA');
$t->write_file('existing_dst', 'OLD');

$r = http(<<EOF);
COPY /src_ow HTTP/1.1
Host: localhost
Destination: /existing_dst
Overwrite: F
Connection: close

EOF

like($r, qr/412/, 'copy overwrite false');
is($t->read_file('existing_dst'), 'OLD', 'copy overwrite false preserved');

$t->write_file('existing_dst2', 'OLD2');

$r = http(<<EOF);
COPY /src_ow HTTP/1.1
Host: localhost
Destination: /existing_dst2
Overwrite: f
Connection: close

EOF

like($r, qr/412/, 'copy overwrite lowercase f');

$r = http(<<EOF);
COPY /src_ow HTTP/1.1
Host: localhost
Destination: /existing_dst
Overwrite: T
Connection: close

EOF

like($r, qr/204 No Content/, 'copy overwrite true');
is($t->read_file('existing_dst'), 'OWDATA', 'copy overwrite true replaced');

$t->write_file('ow_lower', 'OLD');

$r = http(<<EOF);
COPY /src_ow HTTP/1.1
Host: localhost
Destination: /ow_lower
Overwrite: t
Connection: close

EOF

like($r, qr/204 No Content/, 'copy overwrite lowercase t');

$r = http(<<EOF);
COPY /src_ow HTTP/1.1
Host: localhost
Destination: /inv_ow_dst
Overwrite: X
Connection: close

EOF

like($r, qr/400/, 'copy invalid overwrite');

$r = http(<<EOF);
COPY /src_ow HTTP/1.1
Host: localhost
Destination: /inv_ow_dst2
Overwrite: TRUE
Connection: close

EOF

like($r, qr/400/, 'copy invalid overwrite multi-char');

# COPY Depth header

$r = http(<<EOF);
COPY /src_ow HTTP/1.1
Host: localhost
Destination: /depth0_copy
Depth: 0
Connection: close

EOF

like($r, qr/204 No Content/, 'copy file depth 0');

$r = http(<<EOF);
COPY /src_ow HTTP/1.1
Host: localhost
Destination: /depth1_copy
Depth: 1
Connection: close

EOF

like($r, qr/400/, 'copy depth 1 invalid');

# collection/non-collection mismatch

mkdir($t->testdir() . '/srcdir_mm');
$t->write_file('srcdir_mm/inner', 'INNER');

$r = http(<<EOF);
COPY /srcdir_mm/ HTTP/1.1
Host: localhost
Destination: /mismatch_noncol
Connection: close

EOF

like($r, qr/409/, 'copy collection to non-collection');

$r = http(<<EOF);
COPY /src_ow HTTP/1.1
Host: localhost
Destination: /mismatch_col/
Connection: close

EOF

like($r, qr/409/, 'copy non-collection to collection');

# directory tree operations

mkdir($t->testdir() . '/srcdir_tree');
mkdir($t->testdir() . '/srcdir_tree/subdir');
$t->write_file('srcdir_tree/file1', 'FILE1');
$t->write_file('srcdir_tree/subdir/file2', 'FILE2');

$r = http(<<EOF);
COPY /srcdir_tree/ HTTP/1.1
Host: localhost
Destination: /dstdir_tree/
Connection: close

EOF

like($r, qr/201 Created/, 'copy directory tree');
is($t->read_file('dstdir_tree/file1'), 'FILE1', 'copy tree file');
is($t->read_file('dstdir_tree/subdir/file2'), 'FILE2', 'copy tree subdir file');

mkdir($t->testdir() . '/ow_src');
$t->write_file('ow_src/data', 'NEWDATA');
mkdir($t->testdir() . '/ow_dst');
$t->write_file('ow_dst/old', 'OLDDATA');

$r = http(<<EOF);
COPY /ow_src/ HTTP/1.1
Host: localhost
Destination: /ow_dst/
Overwrite: T
Connection: close

EOF

like($r, qr/201 Created/, 'copy dir overwrite existing');
is($t->read_file('ow_dst/data'), 'NEWDATA', 'copy dir overwrite content');

$r = http(<<EOF);
COPY /nonexistent_src HTTP/1.1
Host: localhost
Destination: /some_dst
Connection: close

EOF

like($r, qr/404/, 'copy source not found');

mkdir($t->testdir() . '/existing_dir_dst');

$r = http(<<EOF);
COPY /src_ow HTTP/1.1
Host: localhost
Destination: http://localhost/existing_dir_dst
Connection: close

EOF

like($r, qr/409/, 'copy to existing dir no slash');

# MOVE

$t->write_file('moveme', 'MOVEDATA');

$r = http(<<EOF);
MOVE /moveme HTTP/1.1
Host: localhost
Destination: /moved
Connection: close

EOF

like($r, qr/204 No Content/, 'move file');
ok(!-f $t->testdir() . '/moveme', 'move file source removed');
is($t->read_file('moved'), 'MOVEDATA', 'move file content');

$t->write_file('movedepth', 'x');

$r = http(<<EOF);
MOVE /movedepth HTTP/1.1
Host: localhost
Destination: /movedepth_dst
Depth: 0
Connection: close

EOF

like($r, qr/400/, 'move depth 0 invalid');

$t->write_file('movebody', 'x');

$r = http(<<EOF . '0123456789');
MOVE /movebody HTTP/1.1
Host: localhost
Destination: /movebody_dst
Connection: close
Content-Length: 10

EOF

like($r, qr/415/, 'move body');

$r = http(<<EOF . $chunked);
MOVE /movebody HTTP/1.1
Host: localhost
Destination: /movebody_dst
Connection: close
Transfer-Encoding: chunked

EOF

like($r, qr/415/, 'move body chunked');

mkdir($t->testdir() . '/movedir_nested');
mkdir($t->testdir() . '/movedir_nested/sub');
$t->write_file('movedir_nested/a', 'A');
$t->write_file('movedir_nested/sub/b', 'B');
mkdir($t->testdir() . '/movedir_nested_dst');

$r = http(<<EOF);
MOVE /movedir_nested/ HTTP/1.1
Host: localhost
Destination: /movedir_nested_dst/
Connection: close

EOF

like($r, qr/201 Created/, 'move nested directory');
ok(!-d $t->testdir() . '/movedir_nested', 'move nested source removed');

# DAV disabled

$t->write_file('off/test', 'x');

$r = http(<<EOF . '0123456789');
PUT /off/putfile HTTP/1.1
Host: localhost
Connection: close
Content-Length: 10

EOF

unlike($r, qr/201 Created/, 'dav off - put not handled');

$r = http(<<EOF);
DELETE /off/test HTTP/1.1
Host: localhost
Connection: close
Content-Length: 0

EOF

unlike($r, qr/204 No Content/, 'dav off - delete not handled');

# dav_access

$r = http(<<EOF . 'accessdata');
PUT /access/afile HTTP/1.1
Host: localhost
Connection: close
Content-Length: 10

EOF

like($r, qr/201 Created/, 'dav_access put');

SKIP: {
skip 'permissions on win32', 1 if $^O eq 'MSWin32';

my $mode = (stat($t->testdir() . '/access/afile'))[2] & 07777;
is($mode & 0644, 0644, 'dav_access file permissions');

}

$r = http(<<EOF);
MKCOL /access/subdir/ HTTP/1.1
Host: localhost
Connection: close

EOF

like($r, qr/201 Created/, 'dav_access mkcol');

SKIP: {
skip 'permissions on win32', 1 if $^O eq 'MSWin32';

my $mode = (stat($t->testdir() . '/access/subdir'))[2] & 07777;
ok($mode & 0755, 'dav_access mkcol permissions');

}

###############################################################################

