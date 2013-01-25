package scron::Job;

## Not relevant and probably won't work if not used by scrond
#
#  Uses main:: globals qw($schema $local_tz $config $mason_output $mason $mail_transport)

use strict;
use warnings;
use Params::Validate qw(validate validate_with);
use DateTime::Event::Cron;
use POE qw(Wheel::Run);
use Log::Log4perl qw(get_logger :levels);
use List::Util qw(first);
use Time::HiRes qw(tv_interval gettimeofday);
use Digest::MD5 qw(md5_base64);
use Email::Sender::Simple qw(sendmail);

use base qw(Class::Accessor);
scron::Job->mk_accessors(qw(logger name command));

## Create DateTime::Set::Splay wrapper class

{
    package DateTime::Set::Splay;

    use strict;
    use warnings;
    use base qw(DateTime::Set);

    sub from_set {
        my ($class, %args) = @_;

        my $self = bless $args{set}, $class;
        $self->{_splay} = $args{splay};
        return $self;
    }

    # Create wrapped object calls for the basic Set iterator functions
    no strict 'refs';
    foreach my $method (qw(next previous current closest)) {
        *{__PACKAGE__.'::'.$method} = sub {
            my $self = shift;
            my $super_method = 'SUPER::' . $method;
            my $ret = $self->$super_method(@_);
            return $self->{_splay} ? $ret + $self->{_splay} : $ret;
        };
    }
}

### Class Globals ##

# Define shortcuts that define the '/usr/bin/time' formatting method
# Create in reverse ($_time_formats{percent_cpu} == 'P')
my %_time_formats = reverse (
    P => 'percent_cpu', # user + system time / total running time
    e => 'wall_clock',
    S => 'kernel_clock', # seconds
    U => 'user_clock',

    K => 'avg_total_mem',

    D => 'avg_unshared_data_mem',
    p => 'avg_unshared_stack_mem',
    X => 'avg_shared_text_mem',

    t => 'avg_resident_set_mem',
    M => 'max_resident_set_mem',

    x => 'exit_status',

    c => 'context_switched_invol',
    w => 'context_switched_vol',

    r => 'socket_msgs_received',
    s => 'socket_msgs_sent',
);

# Define units and their abbreviations for time strings ("6 minutes")
my %_time_units = (
    map(($_,             1), qw(s second seconds sec)),
    map(($_,            60), qw(m minute minutes min)),
    map(($_,         60*60), qw(h hour hours)),
    map(($_,      60*60*24), qw(d day days)),
    map(($_,    60*60*24*7), qw(w week weeks)),
    map(($_,   60*60*24*30), qw(M month months)),
    map(($_,  60*60*24*365), qw(y year years)),
);  

my $validation_spec = {
    name          => 0, # we don't need to worry; it'll always be there
    user          => { default => 'root' },
    group         => 0,
    cron          => 1,
    command       => 1,
    time_expected => 0,
    exit_expected => 0,
    concurrency   => { default => '1' },
    template      => 0,
    errors_to     => {
        optional => 1,
        callbacks => { 'valid email' => \&scron::_valid_email },
    },
    email_from    => {
        optional => 1,
        callbacks => { 'valid email' => \&scron::_valid_email },
    },
    email_subject_prefix => 0,
    disable       => 0,
    splay         => 0,
};

### Object Creation ##

sub new {
    my ($class) = shift;
    my %args = validate(@_, $validation_spec);

    # If no group name is given, find the primary group of the user and use that
    if (! $args{group}) {
        my @pw = getpwnam($args{user});
        $args{group} = getgrgid($pw[3]);
    }

    if ($args{time_expected}) {
        # Parse time str to seconds
        $args{time_expected} = _canonicalize_time( $args{time_expected} );
    }

    # The Job object is stored in the schema with all the args (save 'name')
    # in a deflated hash as the 'param' field.  Search for an existing row 
    # of this nature, and if it doesn't exist, create it.

    my %param = (
        map { $_ => $args{$_} }
        grep { ! /^(name)$/ }
        keys %args
    );

    $args{cron_set} = DateTime::Event::Cron->from_cron($args{cron});

    $args{logger} = get_logger('scron::Job');

    my $self = bless \%args, $class;

    if (! $self->config('no_email')) {
        require Email::MIME::Creator;
    }

    my %row = (
        name => $args{name},
        param => \%param,
    );

    $args{job_id} = scron::digest_id(%row);

    $main::schema->do_db('Job', 'create', 
        id => $args{job_id},
        %row,
    );

    return $self;
}

### Object Methods ##

sub run {
    my $self = shift;

    # Check for concurrency violations

    if ($self->{concurrency}) {
        # The number of keys in the running hash is how many concurrent
        # instances are running
        my $count = int @{[ keys %{ $self->{running} } ]};
        if ($count >= $self->{concurrency}) {
            $self->logger->error("Failed to run job '$$self{name}' as max concurrent instances running ($count)");
            return;
        }
    }

    # Create time call with formatting

    # NOTE: if this is going to be modified, make sure each field name is also in %scron::stat_keys
    $self->{_time_fields} = [qw(exit_status wall_clock kernel_clock user_clock avg_total_mem)];
    my $time_cmd = "/usr/bin/time --format='TIME_OUTPUT:::"
        . join(';', map { "$_=%".$_time_formats{$_} } @{ $self->{_time_fields} })
        . "' $$self{command}";

    # Creat the wheel, calling the command

    my $wheel = POE::Wheel::Run->new(
        Program => $time_cmd,

        StdoutEvent => 'job_stdout',
        StderrEvent => 'job_stderr',
        ErrorEvent  => 'job_error',
        CloseEvent  => 'job_close',

        User        => scalar(getpwnam $self->{user}),
        Group       => scalar(getgrnam $self->{group}),
    );

    $self->logger->info("Running '$$self{name}'");
    $self->logger->debug("  $time_cmd");

    my $instance = {};
    $self->{running}{$wheel->ID} = $instance;
    $instance->{wheel} = $wheel;
    $instance->{pid} = $wheel->PID;

    # Record the start of a new instance in the log/db

    $instance->{started_dt} = DateTime->now( time_zone => $main::local_tz );

    my %row = (
        job_id => $self->{job_id},
        host_id => $main::config{main}{_host_id},
        start => $instance->{started_dt}->strftime('%F %T'),
        disposition => $scron::dispositions{running},
    );

    $instance->{instance_id} = scron::digest_id(%row);

    $main::schema->do_db('Instance', 'create',
        id => $instance->{instance_id},
        %row,
    );

    $instance->{started} = [gettimeofday];

    # Set checker event if a time expected

    if ($self->{time_expected}) {
        $instance->{check_alarm} = $poe_kernel->alarm_set( job_check => (time + $self->{time_expected}), $self, $wheel->ID );
    }
}

### POE States ##

sub stdout {
    my ($kernel, $heap, $input, $wheel_id) = @_[KERNEL, HEAP, ARG0, ARG1];
    my $job = first { $_->{running} && $_->{running}{$wheel_id} } @{ $heap->{jobs} };
    if (! $job) {
        $job->logger->error("No job found for input '$input' [$wheel_id]");
        return;
    }

    my $instance = $job->{running}{$wheel_id};

    $job->record_instance_event($instance, $input, 'stdout');

    $job->logger->debug("Input from job $$job{name}: $input");
}

sub stderr {
    my ($kernel, $heap, $input, $wheel_id) = @_[KERNEL, HEAP, ARG0, ARG1];
    my $job = first { $_->{running} && $_->{running}{$wheel_id} } @{ $heap->{jobs} };
    if (! $job) {
        get_logger()->error("No job found for error '$input' [$wheel_id]");
        return;
    }

    my $instance = $job->{running}{$wheel_id};

    if (my ($time_output) = $input =~ /^TIME_OUTPUT:::(.+)/) {
        my @pairs = split /;/, $time_output;
        my %time_output = map { split /=/, $_, 2 } @pairs;
        $instance->{time_output} = \%time_output;
        return;
    }
    if ($input =~ /^Command exited with non-zero status \d+$/) {
        # This is in the time output, so ignore
        return;
    }

    $job->record_instance_event($instance, $input, 'stderr');

    $job->logger->debug("Error from job $$job{name}: $input");
}

sub error {
    my ($kernel, $heap, $operation, $errnum, $errstr, $wheel_id) = @_[KERNEL, HEAP, ARG0..ARG3];
    my $job = first { $_->{running} && $_->{running}{$wheel_id} } @{ $heap->{jobs} };
    if (! $job) {
        get_logger()->error("No job found for run error '$errstr' [$wheel_id]");
        return;
    }
    if ($errnum == 0 && $errstr eq '') {
        # child process closed STDOUT or STDERR; ignore assuming closed() directly after this
        return;
    }
    $job->logger->error("Run error from job $$job{name}: $operation, $errnum, $errstr");
}

sub closed {
    my ($kernel, $heap, $wheel_id) = @_[KERNEL, HEAP, ARG0];
    my $job = first { $_->{running} && $_->{running}{$wheel_id} } @{ $heap->{jobs} };
    if (! $job) {
        get_logger()->error("No job found for closed() [$wheel_id]");
        return;
    }
    $job->logger->debug("Job $$job{name} has closed");

    # Record the run details
    my $instance = delete $job->{running}{$wheel_id};
    delete $instance->{wheel};
    $instance->{run_time} = tv_interval($instance->{started});

    # Was it an error?

    my (@errors, %error_types);
    if (exists $job->{exit_expected} && $job->{exit_expected} != $instance->{time_output}{exit_status}) {
        push @errors, "Unexpected exit status ".$instance->{time_output}{exit_status};
        $error_types{exit_status} = 1;
    }
    if (exists $job->{time_expected} && $instance->{run_time} > $job->{time_expected}) {
        push @errors, "Took ".($instance->{run_time} - $job->{time_expected})." s longer than expected (".$job->{time_expected}.")";
        $error_types{run_time} = 1;
    }
    if ($instance->{stderr_count}) {
        push @errors, "Encountered ".$instance->{stderr_count}." stderr messages";
        $error_types{stderr_output} = 1;
    }

    $instance->{finish_dt} = DateTime->now( time_zone => $main::local_tz );

    $main::schema->do_db('Instance', 'update', { id => $instance->{instance_id} },
        finish      => $instance->{finish_dt}->strftime('%F %T'),
        disposition => $scron::dispositions{@errors ? 'failed' : 'success'},
    );

    # Create the stat values
    my %stats = (%{ $instance->{time_output} }, pid => $instance->{pid});
    while (my ($key, $value) = each %stats) {
        my $stat_key_id = $scron::stat_keys{$key};
        if (! defined $stat_key_id) {
            die "Stat key '$key' doesn't have a key <=> id mapping in scron.pm";
        }

        #printf STDERR "Instance %d reporting %s => %.3f\n", $instance->{instance_row}->id, $key, $value;
        $main::schema->do_db('InstanceStatValue', 'create',
            instance_id => $instance->{instance_id},
            instance_stat_key_id => $stat_key_id,
            value => $value,
        );
    }

    if (@errors) {
        $job->logger->debug("Encountered ".scalar(@errors)." errors on $$job{name}:");
        $job->logger->debug("  $_") foreach @errors;

        $job->notify(
            instance => $instance,
            action => 'completed_with_errors',
            errors => \@errors,
            error_types => \%error_types,
            attach_stderr => 1,
            attach_stdout => 1,
        );
    }
    else {
        $job->notify(
            instance => $instance,
            action => 'completed',
        );
    }

    # Stop alarm
    if ($instance->{check_alarm}) {
        $poe_kernel->alarm_remove($instance->{check_alarm});
    }
}

sub check {
    my ($kernel, $heap, $job, $wheel_id) = @_[KERNEL, HEAP, ARG0, ARG1];
    my $instance = $job->{running}{$wheel_id};

    $job->notify(
        instance => $instance,
        action => 'time_exceeded',
    );

    $job->logger->error("Job $$job{name} taking too long");
}

## notify()
#
#  Given an instance and an action name, notify the interested parties about
#  the execution of this job.  Template is a mason component name, and args
#  can be passed to this template.

sub notify {
    my ($self) = shift;

    my %params = validate_with(
        params => \@_,
        spec => {
            action => 1,
            instance => 1,
        },
        allow_extra => 1,
    );

    $params{job} = $self;

    # Pass the notify along to the plugins
    foreach my $plugin (@main::plugins) {
        $plugin->notify(\%params);
    }

    # Do nothing further if it's completed successfully
    if ($params{action} eq 'completed') {
        return;
    }

    # Plugin may have specified to do no email
    return if $params{no_email};

    # Or the server may be configured for no email
    return if $self->config('no_email');

    ## Compose email

    # TODO: respect the job's 'template' config option

    $main::mason_output = '';
    my $return_value = $main::mason->exec(
        '/'.$params{action}.'.mas',
        %params,
    );

    my $to = $self->config('errors_to');
    $to = ref($to) ? join(', ', @$to) : $to;

    my $subject = $self->{name};
    if ($return_value && ref($return_value) && ref($return_value) eq 'HASH' && $return_value->{subject}) {
        $subject = $return_value->{subject};
    }
    $subject = $self->config('email_subject_prefix') . $subject;

    # Define extra MIME parts to be included

    my %extra_parts;

    # User may want an event log attached
    if (grep { /^attach_/ } keys %params) {
        my @events = $main::schema->do_select('Event',
            instance_id => $params{instance}{instance_id},
        );
        foreach my $event (sort { $a->{offset} <=> $b->{offset} } @events) {
            my $type = $scron::events_idx{ $event->{type} };
            next unless ($params{'attach_'.$type});

            # Resolve the time of the event by adding it's offset (seconds since start)
            # to the start time object
            push @{ $extra_parts{$type} }, sprintf '[%s] %s',
                $params{instance}{started_dt}->clone()->add( seconds => $event->{offset} )->strftime('%T'),
                $event->{details},
                ;
        }
        if (! @events && $main::schema->offline) {
            $extra_parts{error} = [ "scron can't retrieve the output/error log, as it's currently offline from the database" ];
        }
    }

    # The values of %extra_parts isa array of lines; join them into strings
    my @extra_parts;
    foreach my $key (sort keys %extra_parts) {
        push @extra_parts, Email::MIME->create(
            attributes => {
                name => "$key output",
            },
            body => join("\n", @{ $extra_parts{$key} }),
        );
    }

    my $email = Email::MIME->create(
        header => [
            From => $self->config('email_from'),
            To   => $to,
            Subject => $subject,
        ],
        parts => [
            $main::mason_output,
            @extra_parts,
        ],
    );

    # Send email

    if ($params{email_callback}) {
        $params{email_callback}->($email->as_string);
    }
    elsif ($ENV{SCRON_TESTING}) {
        $self->logger->info("Would send email:\n" . ( '=' x 80 ) . "\n" . $email->as_string . ( '=' x 80 ));
    }
    else {
        sendmail($email->as_string, { transport => $main::mail_transport });
    }
}


### Utilities

sub config {
    my ($self, $key) = @_;

    if ($self->{$key}) {
        return $self->{$key};
    }
    return $main::config{main}{$key};
}

sub record_instance_event {
    my ($self, $instance, $text, $type) = @_;

    my $offset = tv_interval($instance->{started});
    my %event = (
        instance_id => $instance->{instance_id},
        type => $scron::events{$type},
    );

    # Split the text into segments of 256 bytes, keeping the offset unique by stepping it each time
    my $count = 0;
    while ($text) {
        my $segment = substr $text, 0, 255, '';
        $main::schema->do_db('Event', 'create',
            %event,
            offset => $offset + ($count++ * 0.000001),
            details => $segment,
        );
    }

    $instance->{$type . '_count'}++;
}

sub validation_spec {
    return $validation_spec;
}

# turn a string in the form "[number] [unit]" into an explicit number
# of seconds from the present.  E.g, "10 minutes" returns "600"
# code from Cache::BaseCache

sub _canonicalize_time {
    my ($p_expires_in) = @_;

    my $secs; 
    if ($p_expires_in =~ /^\s*([+-]?(?:\d+|\d*\.\d*))\s*$/) {
        $secs = $p_expires_in;
    }
    elsif ($p_expires_in =~ /^\s*([+-]?(?:\d+|\d*\.\d*))\s*(\w*)\s*$/
            and exists( $_time_units{ $2 })) {
        $secs = ($_time_units{ $2 }) * $1;
    }
    else {
        die "Invalid time '$p_expires_in'";
    }

    return $secs;
}

1;
