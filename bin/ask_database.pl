#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib qq{$FindBin::Bin/};
use scron;

my $hostname = `hostname`;
chomp $hostname;

my $schema = scron::Model->connect('dbi:mysql:database=scron;host=localhost', 'scron', 'scronpw');

my $instances = $schema->resultset('Instance')->search(
    {
        host => $hostname,
        disposition => $scron::dispositions{failed},
    },
    {
        order_by => 'start DESC',
        prefetch => 'Job',
    }
);

while (my $instance = $instances->next) {
    my $Job = $instance->Job;

    print "Job " . $Job->name . " ran on $hostname at " . $instance->start . "\n";
}
