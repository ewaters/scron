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

my $db_file = "$tmp_dir/scron_sqlite.db";
my $config_fn = $tmp_dir . '/test.ini';
my $scrond = "perl -I$FindBin::Bin/../lib $FindBin::Bin/../bin/scrond --config $config_fn";
my $email_output_dir = $tmp_dir . '/failed_job_emails';

# Create a test config

my $long_output_length = 589;
my $plugins = 'Testing';

open my $out, '>', $config_fn or die "Couldn't open $config_fn: $!";
print $out <<EOF;
[main]
  template_dir = $FindBin::Bin/../templates
  template_cache_dir = $tmp_dir/scron_cache
  log_dir = $tmp_dir
  sqlite = $db_file
  load_plugins = $plugins

[File Listing]
  cron = * * * * *
  command = ls /var/run

[Long Output]
  cron = */15 * * * *
  command = "perl -e 'print \\"=\\" x $long_output_length . \\"\\\\n\\"'"

[Different User]
  cron = * * * * *
  user = nobody
;; Try not specifying the group, as it'll be auto-detected
; group = nogroup
  command = "perl -e 'print scalar(getpwuid(\\\$>)).\\" \\".scalar(getgrgid(\\\$))).\\"\\\\n\\"'"

[Invalid Exit Status]
  cron = * * * * *
  exit_expected = 0
  command = "perl -e 'exit 1'"
  testing_email_output_dir = $email_output_dir

[Long Running Process]
  cron = * * * * *
  exit_expected = 0
  time_expected = 2 sec
  command = "perl -e 'sleep 3; exit 0'"
  testing_email_output_dir = $email_output_dir
EOF

close $out;
ok(-f $config_fn, "Created test config");

## Deploy the db

system "$scrond --deploy";
ok(-f $db_file, "SQLite db initialized");

## Perform basic test, returning after one run

system "SCRON_TESTING=1 DBIC_DEBUG=SQL $scrond --debug";

## Check that the jobs completed successfully

my $schema = scron::Online::Model->connect("dbi:SQLite:".$db_file);
ok($schema, "Connected to SQLite");

test_job('File Listing');

{
    my ($job, $instance, @events) = test_job('Long Output');
    # Check that the long output was properly split
    my $concat = '';
    $concat .= $_->details foreach @events;
    is(length $concat, $long_output_length, "Length of long output correct");
}

SKIP: {
    skip "Must be root to try changing user/group", 1 unless $< == 0;

    my ($job, $instance, @events) = test_job('Different User');
    ok($events[0]->details =~ m/nobody nogroup/, "Process ran as nobody/nogroup");
}

test_job('Invalid Exit Status', 'failed', 0);

ok(-f $email_output_dir . '/Invalid Exit Status', 'Job created email output');

test_job('Long Running Process', 'failed', 0);

# Long running proc generates two email outputs; the first when it goes over, the second when it's over
ok(-f $email_output_dir . '/Long Running Process', 'Job created email output');
ok(-f $email_output_dir . '/Long Running Process.0', 'Job created email output');

## Cleanup

$schema->storage->disconnect;

#system "rm -rf $tmp_dir";

sub test_job {
    my ($job_name, $status_expected, $output_expected) = @_;
    my $job = $schema->resultset('Job')->search({
        name => $job_name,
    })->first;
    ok($job, "Found job '$job_name'");

    $status_expected ||= 'success';
    my $instance = $job->Instances->first;
    is($instance->disposition, $scron::dispositions{$status_expected}, "Job '$job_name' completed with $status_expected");

    $output_expected = 1 if ! defined $output_expected;
    my @events = $instance->Events;
    ok($output_expected ? int @events > 0 : int @events == 0, "Job '$job_name' had expected output");

    return ($job, $instance, @events);
}

