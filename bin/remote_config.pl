#!/usr/bin/env perl

use strict;
use warnings;
use CGI::Carp qw(fatalsToBrowser);
use CGI qw(:standard);
use Digest::MD5 qw(md5_hex);

## Configure

my $config_dir = $ENV{CONFIG_DIR};

## Setup

local $/ = undef;
my $hostname = param('hostname');
my @classes  = param('class');

if (! $hostname) {
    print header(-status => '400 Invalid call');
    print p("You must provide a 'hostname' parameter");
    exit;
}

# Treat hostname as a class
unshift @classes, 'host.' . $hostname;

## Handle request

# Expand classes to sub directories

my @sub_dirs;
foreach my $class (@classes) {
    my @parts = split /\./, $class;
    foreach my $i (0..$#parts) {
        push @sub_dirs, join '/', @parts[ 0 .. $i ];
    }
}

# Load each .ini file from each sub directory in turn, descending down the tree.
# Files named the same get overridden in sub directories, as well in other
# classes, so order matters somewhat.

my %config;
foreach my $sub_dir (@sub_dirs) {
    my $dir = $config_dir . '/' . $sub_dir;
    next if ! -d $dir;
    foreach my $ini (glob "$dir/*.ini") {
        my ($base_name) = $ini =~ m{([^/]+)\.ini$};

        my $config = slurp($ini);
        my $config_sig = -f $ini . '.sig' ? slurp($ini . '.sig') : '';

        $config{$base_name} = "<config><data>$config</data><sig>$config_sig</sig></config>\n";
    }
}
my $data = join '', values %config;

# Calculate an ETag and send it along
my $digest = md5_hex($data);
print header(-ETag => $digest);

# If HEAD, we don't need the rest printed
exit if $ENV{REQUEST_METHOD} eq 'HEAD';

# Print the data and exit
print $data;

exit;

## Utilities

sub slurp {
    open my $in, '<', shift or die;
    my $return = <$in>;
    close $in;
    return $return;
}
    
