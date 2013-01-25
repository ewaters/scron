package scron::Plugin::Testing;

use strict;
use warnings;
use File::Path;
use base qw(scron::Plugin);

sub update_validate_spec {
    my ($self, $block, $spec) = @_;

    $spec->{testing_email_output} = 0;
    $spec->{testing_email_output_dir} = 0;

    return;
}

sub notify {
    my ($self, $params) = @_;

    return if $params->{action} eq 'completed';

    my ($email_output_fn, $email_output_dir) =
        map { $params->{job}->config($_) }
        qw(testing_email_output testing_email_output_dir);

    return unless $email_output_fn || $email_output_dir;
    my $base_output_fn = $email_output_dir ? $email_output_dir . '/' . $params->{job}{name} : $email_output_fn;

    $params->{email_callback} = sub {
        my $email = shift;

        eval {
            my $output_fn = $base_output_fn;
            my $count = 0;
            while (-e $output_fn) {
                $output_fn = $base_output_fn . '.' . $count++;
            }
            my ($base_dir) = $output_fn =~ m{^(.+)/[^/]+$};
            -d $base_dir || mkpath($base_dir) || die "Can't make '$base_dir': $!";

            open my $out, '>', $output_fn or die "Can't create $output_fn: $!";
            print $out $email;
            close $out;
        };
        if ($@) {
            $params->{job}->logger->error("Plugin::Testing->notify() failed to store email to file: $@");
        }

        return;
    };

    return;
}

1;
