#!/usr/bin/env perl
use strict;
use warnings;
use MaxMind::DB::Writer::Tree;

sub write_db_file {
    my ($tree, $filename) = @_;
    open my $fh, '>:raw', $filename or die "Cannot open $filename: $!";
    $tree->write_tree($fh);
    close $fh;
    print "Generated $filename\n";
}

do {
    my %types = (
        country => 'map',
        names   => 'map',
        iso_code=> 'utf8_string',
        en      => 'utf8_string',
    );
    my $map_key_type_callback = sub { $types{ $_[0] } };

    my $country_tree = MaxMind::DB::Writer::Tree->new(
        ip_version            => 6,
        record_size           => 28,
        database_type         => 'GeoIP2-Country',
        languages             => ['en'],
        description           => { en => 'Test Country DB' },
        map_key_type_callback => $map_key_type_callback,
        alias_ipv6_to_ipv4    => 1,
    );

    # Insert some sample networks
    $country_tree->insert_network('8.8.8.0/24',
            { country => { iso_code => 'US', names => { en => 'United States' } } }
    );
    $country_tree->insert_network('2606:4700:4700::/48',
            { country => { iso_code => 'CA', names => { en => 'Canada' } } }
    );

    # Write the database file
    write_db_file($country_tree, 'country.mmdb');
};

