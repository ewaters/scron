package scron;

=head1 NAME

scron - Supervised Cron

=head1 DESCRIPTION

Cron is great for routine tasks on a single machine where one person is the sysadmin.  When you begin to have a multi-admin environment, with hundreds of machines, and you need to keep track of vital routine jobs, cron fails to live up to the task.

scrond, a supervised cron daemon, calls cron-like commands, storing the output of the command and notifying admins about potential error conditions and states.  It expands the cron toolset by allowing one to specify how long a process is expected to take, what the error condition is expected to be, and other similar controls.  It allows one to keep closer track on cron jobs.

=head1 USAGE

See the man page for L<scrond> for detailed usage.

=head1 AUTHOR

Eric Waters <ewaters@gmail.com>

=head1 COPYRIGHT

Copyright (c) 2013 Eric Waters and XMission LLC (http://www.xmission.com/). All rights reserved. This program is free software; you can redistribute it and/or modify it under the same terms as Perl itself.

The full text of the license can be found in the LICENSE file included with this module.

=cut

use strict;
use warnings;
use YAML;
use Digest::MD5 qw(md5_base64);

our $VERSION = 0.3;

our %dispositions = (
    running => 1,
    success => 2,
    failed => 3,
);
our %dispositions_idx = reverse %dispositions;

our %events = (
    stdout => 1,
    stderr => 2,
);
our %events_idx = reverse %events;

our (%stat_keys, %stat_keys_idx);
{
    # DO NOT reorder this array; only add on to the end
    my @stats = (qw(
        exit_status
        wall_clock
        kernel_clock
        user_clock
        avg_total_mem
        pid
    ));
    @stat_keys{@stats} = 1 .. int @stats;
    %stat_keys_idx = reverse %stat_keys;
}

sub dumper_inflate {
    Load($_[0]);
}

sub dumper_deflate {
    Dump($_[0]);
}

sub digest_id {
    return md5_base64(Dump(\@_));
}

sub _valid_email {
    eval {
        require Email::Address;
    };
    if ($@) {
        print STDERR "Can't check email addresses for validity without Email::Address\n";
        return 1;
    }

    my $address = $_[0];
    $address = join ', ', @$address if ref $address;
    
    my @addresses = Email::Address->parse($address);
    return 1 if @addresses;
    return 0;
}

package scron::Model;

use strict;
use warnings;
use YAML;
use Carp;
use SQL::Abstract;
use DBI;
use File::Copy qw(move);
use Fcntl ':flock'; # import LOCK_* constants
use Log::Log4perl qw(get_logger :levels);

use base qw(Class::Accessor);
__PACKAGE__->mk_accessors(qw(sql_maker dbh dsn replay_log replay_count logger offline replaying));

sub connect {
    my ($class, @dsn) = @_;

    my %self = (
        sql_maker => SQL::Abstract->new(),
        dsn => \@dsn,
        dbh_error_times => [],
        replay_log => $main::config{main}{db_replay_log},
        logger => get_logger('scron::Model'),
    );
    my $self = bless \%self, $class;

    $self->reconnect();

    return $self;
}

sub reconnect {
    my $self = shift;

    # If I've failed before, wait until the backoff time is reached
    if (my $last_attempt = $self->{dbh_error_times}[0]) {
        my $attempts = int @{ $self->{dbh_error_times} };
        my $backoff = $last_attempt->[0] + 2 ** $attempts;
        my $wait = $backoff - time;
        if ($wait <= 0) {
            $self->logger->debug(__PACKAGE__."::reconnect() backoff of $backoff already elapsed $wait seconds ago");
        }
        else {
            if (! $self->{report_backoff} || $self->{report_backoff} != $backoff) {
                $self->logger->debug(__PACKAGE__."::reconnect() waiting $wait seconds before retrying failed connection");
                $self->{report_backoff} = $backoff;
            }
            return $self;
        }
    }

    if ($self->{dbh}) {
        eval { $self->{dbh}->disconnect() };
    }

    # Try reconnecting
    eval {
        $self->{dbh} = DBI->connect(@{ $self->dsn }, { RaiseError => 1, PrintError => 0 });
    };
    if ($@) {
        $self->{offline} = 1;
        unshift @{ $self->{dbh_error_times} }, [ time, $@ ];
        $self->logger->debug(__PACKAGE__."::reconnect() failed: $@");
    }
    else {
        $self->{offline} = 0;
        $self->{dbh_error_times} = [];
    }

    return $self;
}

sub do_db {
    my ($self, $resultset, $action, @args) = @_;

    # Rename action to SQL::Maker method name
    $action = 'insert' if $action eq 'create';

    # Use where for 'update'
    my $where;
    $where = shift @args if $action eq 'update';

    # Deflate data structures
    my %args = @args;
    while (my ($key, $value) = each %args) {
        next unless ref $value;
        $args{$key} = scron::dumper_deflate($value);
    }

    # Find the SQL statement and bind params
    my ($sql, @bind) = $self->sql_maker->$action(lc($resultset), \%args, ($where ? ($where) : ()));

    $self->execute_sql({ sql => $sql, bind => \@bind, _orig_time => time, action => $action, resultset => $resultset, });
}

sub do_select {
    my ($self, $resultset, %where) = @_;

    if (! $self->ping || $self->offline) {
        $self->reconnect();
    }
    if ($self->offline) {
        return ();
    }

    my ($sql, @bind) = $self->sql_maker->select(lc($resultset), '*', \%where);
    my $sth = $self->dbh->prepare($sql);
    $sth->execute(@bind);

    my @rows;
    while (my $row = $sth->fetchrow_hashref) {
        push @rows, $row;
    }
    return @rows;
}

sub execute_sql {
    my ($self, $request) = @_;

    #$self->logger->debug(Dump($request));

    # Ensure I'm connected (or at least try again if backoff is elapsed)
    if (! $self->ping || $self->offline) {
        $self->reconnect();
    }

    # Attempt db storage
    my $successful = 0;
    if (! $self->offline) {
        # 'column id is not unique' and other similar errors will for some reason warn(),
        # and I can't seem to supress it, so remap these as die's
        $SIG{__WARN__} = sub { die $_[0] };

        eval {
            my $sth = $self->dbh->prepare($request->{sql});
            my $rv = $sth->execute(@{ $request->{bind} });
            if (! $rv) {
                die $sth->errstr;
            }
        };
        if (my $ex = $@) {
            if ($ex =~ /prepare failed: no such column/) {
                croak $ex;
            }
            elsif ($ex =~ /execute failed: (column id is not unique|Duplicate entry)/) {
                # Do nothing; uniqueness is not import on the 'id' column
                # If it's in the db, it's probably fine
                $successful = 1;
            }
            else {
                # Do nothing; I'll store it to file
                $self->logger->error("DBI error; storing to replay log: $@");
            }
        }
        else {
            $successful = 1;
        }
    }

    if (! $successful) {
        # Store to file
        $self->store($request);
        $self->{replay_count}++;
        #$self->logger->debug("Stored $$request{resultset} $$request{action} request to replay log");
    }

    # If I'm now reconnected to the database, let's try replaying the log
    if ($successful && $self->need_replay) {
        $self->logger->debug("Reconnected to db; replaying log of failed requests");
        $self->replay();
    }
}

sub store {
    my ($self, $request) = @_;

    open my $out, '>>', $self->{replay_log} or die "Can't open $$self{replay_log} for appending: $!";
    flock $out, LOCK_EX;
    print $out Dump({ %$request, _store_time => time });
    flock $out, LOCK_UN;
    close $out;

    return;
}

sub need_replay {
    my $self = shift;
    return ! $self->replaying && ($self->replay_count || -e $self->replay_log);
}

sub replay {
    my ($self) = @_;

    if (! -f $self->{replay_log}) {
        die "Replay log $$self{replay_log} doesn't exist";
    }

    if ($self->offline) {
        $self->reconnect();
    }
    if ($self->offline) {
        $self->logger->error("Can't replay: still offline");
        return 0;
    }
    
    # Get a unique tmp file to move the replay log to
    my $tmp_file = $self->{replay_log} . '.tmp';
    {
        my $tmp_count = 0;
        while (-e $tmp_file) {
            $tmp_file = $self->{replay_log} . '.' . $tmp_count++ . '.tmp';
        }
    }

    # Move it out of place while we work on it
    move($self->{replay_log}, $tmp_file) or die "Can't move $$self{replay_log} to $tmp_file: $!";
    $self->{replay_count} = 0;

    $self->replaying(1);

    # Setup simple function to handle a single function
    my $record = '';
    my $count = 0;
    my $do_one_record = sub {
        my ($request) = Load($record);
        $request->{_replay_count}++;
        $self->execute_sql($request);
        $record = '';
        $count++;
    };

    open my $in, '<', $tmp_file or die "Can't open $tmp_file for reading: $!";
    flock $in, LOCK_EX;
    while (my $line = <$in>) {
        chomp $line;
        if ($line eq '---' && $record) {
            $do_one_record->();
        }
        $record .= $line . "\n";
    }
    flock $in, LOCK_UN;
    close $in;

    # Handle the last record read (no end delineator)
    $do_one_record->() if $record;

    $self->replaying(0);

    unlink $tmp_file or die "Can't remove $tmp_file: $!";

    if (-f $self->{replay_log}) {
        $self->logger->error("Replaying of replay log failed; dropped back to log");
    }
    else {
        $self->logger->debug("Replayed $count do_db requests without drop back");
    }

    return 1;
}

sub ping {
    my ($self) = @_;

    return 0 if ! $self->dbh;
    return $self->dbh->ping;
}

1;
