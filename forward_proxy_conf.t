#!/usr/bin/perl

# Tests for forward_proxy configuration conflicts and inheritance.

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

my $t = Test::Nginx->new()->has(qw/http proxy/)->plan(5);

$t->write_file('error.log', '');

my ($rc, $out) = config_test($t, <<'EOF');
daemon off;

events {
}

http {
    server {
        listen       127.0.0.1:%%PORT_8080%%;
        server_name  localhost;

        location / {
            forward_proxy on;
            proxy_pass http://127.0.0.1:%%PORT_8081%%;
        }
    }
}
EOF
ok($rc != 0 && $out =~ /incompatible with/ms,
	'same location rejects forward_proxy then proxy_pass');

($rc, $out) = config_test($t, <<'EOF');
daemon off;

events {
}

http {
    server {
        listen       127.0.0.1:%%PORT_8082%%;
        server_name  localhost;

        location / {
            proxy_pass http://127.0.0.1:%%PORT_8083%%;
            forward_proxy on;
        }
    }
}
EOF
ok($rc != 0 && $out =~ /incompatible with/ms,
	'same location rejects proxy_pass then forward_proxy');

($rc, $out) = config_test($t, <<'EOF');
daemon off;

events {
}

http {
    server {
        listen       127.0.0.1:%%PORT_8084%%;
        server_name  localhost;

        location / {
            forward_proxy on;

            location /child {
                proxy_pass http://127.0.0.1:%%PORT_8085%%;
            }
        }
    }
}
EOF
ok($rc != 0 && $out =~ /incompatible with/ms,
	'inherited forward_proxy rejects child proxy_pass');

($rc, $out) = config_test($t, <<'EOF');
daemon off;

events {
}

http {
    server {
        listen       127.0.0.1:%%PORT_8086%%;
        server_name  localhost;

        location / {
            proxy_pass http://127.0.0.1:%%PORT_8087%%;

            location /child {
                forward_proxy on;
            }
        }
    }
}
EOF
ok($rc == 0,
	'child forward_proxy is allowed under parent proxy_pass');

($rc, $out) = config_test($t, <<'EOF');
daemon off;

events {
}

http {
    server {
        listen       127.0.0.1:%%PORT_8088%%;
        server_name  localhost;

        location / {
            forward_proxy on;

            location /child {
                forward_proxy off;
                proxy_pass http://127.0.0.1:%%PORT_8089%%;
            }
        }
    }
}
EOF
ok($rc == 0, 'child forward_proxy off allows proxy_pass override');

###############################################################################

sub config_test {
	my ($t, $conf) = @_;

	my $testdir = $t->testdir();
	my $cmd = join ' ',
		shell_quote($Test::Nginx::NGINX),
		'-p', shell_quote($testdir . '/'),
		'-c', shell_quote('nginx.conf'),
		'-e', shell_quote('error.log'),
		'-t', '2>&1';

	$t->write_file_expand('nginx.conf', $conf);
	mkdir $testdir . '/logs';

	my $out = `$cmd`;
	my $rc = $? >> 8;

	return ($rc, $out);
}

sub shell_quote {
	my ($value) = @_;

	$value =~ s/'/'"'"'/gms;

	return "'$value'";
}

###############################################################################
