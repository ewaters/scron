#!/usr/bin/env perl

use strict;
use warnings;
use scron;
use DateTime;

-f "example.db" && unlink "example.db";
my $schema = scron::Model->connect("dbi:SQLite:example.db");
$schema->deploy();

my $job = $schema->resultset('Job')->create({
	host => 'mammon',
	name => 'testing',
	param => {
		test => "blah blah blah",
	},
});

print "Created job ".$job->name.", id ".$job->id."\n";
print "  param: ".$job->param->{test}."\n";

my $instance = $job->create_related('Instances', {
	start => DateTime->now( time_zone => 'local' )->strftime('%F %T'),
	disposition => $scron::dispositions{'running'},
});

print "Created instance ".$instance->id." at ".$instance->start."\n";

my $event = $instance->create_related('Events', {
	offset => 1.000,
	type => $scron::events{'stdout'},
	details => "This is a stdout log entry",
});

print "Created event '".$event->details."'\n";

$event = $instance->create_related('Events', {
	offset => 1.001,
	type => $scron::events{'stdout'},
	details => "This is another stdout log entry",
});

1;
