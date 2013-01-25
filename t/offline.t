#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use Test::More qw(no_plan);

BEGIN {
    use_ok('scron');
    use_ok('scron::Online');
}

# Create a temp directory
my $tmp_dir = "$FindBin::Bin/tmp.$$";
if (-d $tmp_dir) {
    my $count = 0;
    while (-d $tmp_dir) {
       $tmp_dir = "$FindBin::Bin/tmp.$$.".$count++;
    }
}
mkdir $tmp_dir;
ok(-d $tmp_dir, "Created temp directory");

my $db_file = "$tmp_dir/sqlite.db";
my $replay_log = "$tmp_dir/scron.replay";
my $config_fn = $tmp_dir . '/test.ini';
my $scrond = "perl -I$FindBin::Bin/../lib $FindBin::Bin/../bin/scrond --config $config_fn";

# Create a test config

my $long_output_length = 589;

write_config('mysql');

## Deploy the db

## Perform basic test (will go to offline mode), returning after one run

system "SCRON_TESTING=1 DBIC_DEBUG=SQL $scrond --debug";

## Check that the jobs completed successfully

ok(-f $replay_log, "Replay log exists");

## Now modify the configuration to have a valid db

write_config('sqlite');

## Deploy the db

system "$scrond --deploy";
ok(-f $db_file, "SQLite db initialized");

## Perform basic test (this time online), returning after one run

system "SCRON_TESTING=1 DBIC_DEBUG=SQL $scrond --debug";

## Check that all the jobs completed successfully, offline and non

my $schema = scron::Online::Model->connect("dbi:SQLite:".$db_file);
ok($schema, "Connected to SQLite");

test_job('File Listing', 2);

{
    my ($job, $instance, @events) = test_job('Long Output', 2);
    # Check that the long output was properly split
    my $concat = '';
    $concat .= $_->details foreach @events;
    is(length $concat, $long_output_length, "Length of long output correct");
}

## Cleanup

$schema->storage->disconnect;

#system "rm -rf $tmp_dir";

sub test_job {
    my ($job_name, $expected_count) = @_;
    my $job = $schema->resultset('Job')->search({
        name => $job_name,
    })->first;
    ok($job, "Found job '$job_name'");

    my @instances = $job->Instances->all;
    is(int @instances, $expected_count, "Found proper number of instances of job '$job_name'");

    my @events;
    foreach my $instance (@instances) {
        is($instance->disposition, $scron::dispositions{success}, "Job '$job_name' completed successfully");

        @events = $instance->Events;
        ok(int @events > 0, "Job '$job_name' had output");
    }

    return ($job, $instances[0], @events);
}

sub write_config {
    my $db_type = shift;

    my $db_settings;
    if ($db_type eq 'mysql') {
        $db_settings = <<EOF;
  mysql_user = blah
  mysql_pass = bleh
  mysql_host = nonexistant.host
  mysql_database = haha
EOF
    }
    elsif ($db_type eq 'sqlite') {
        $db_settings = <<EOF;
  sqlite = $db_file
EOF
    }

    open my $out, '>', $config_fn or die "Couldn't open $config_fn: $!";
    print $out <<EOF;
[main]
  template_cache_dir = $tmp_dir/scron_cache
  log_dir = $tmp_dir
  db_replay_log = $replay_log
$db_settings

[File Listing]
  cron = * * * * *
  command = ls /var/run

[Long Output]
  cron = */15 * * * *
  command = "perl -e 'print \\"=\\" x $long_output_length . \\"\\\\n\\"'"
EOF
    close $out;
    ok(-f $config_fn, "Created test config");
}
