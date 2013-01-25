#!/usr/bin/env perl

use strict;
use warnings;

$| = 1; # autoflush STDOUT

print "Yo yo!\n";

print STDERR "Got an error\n";

sleep 140;

print STDERR "Returning with value 1\n";

exit 1;
