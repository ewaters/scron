package scron::Plugin;

use strict;
use warnings;
use Log::Log4perl qw(get_logger);
use Module::Pluggable
        require => 1,
        sub_name => 'classes',
        search_path => 'scron::Plugin',
        ;

sub new {
    my ($class, %self) = @_;

    return bless \%self, $class;
}

sub start {
    my ($self) = @_;

    return;
}

sub stop {
    my ($self) = @_;

    return;
}

sub update_validate_spec {
    my ($self, $block, $spec) = @_;

    return;
}

sub notify {
    my ($self, $params) = @_;

    return;
}

sub modify_config {
    my ($self, $config) = @_;

    return;
}

my %loggers;
sub logger {
    my $self = shift;
    my $class = ref $self;
    if (! $loggers{$class}) {
        $loggers{$class} = get_logger($class);
    }
    return $loggers{$class};
}

1;
