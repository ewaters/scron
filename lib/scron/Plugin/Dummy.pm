package scron::Plugin::Dummy;

use strict;
use warnings;
use base qw(scron::Plugin);

sub update_validate_spec {
    my ($self, $block, $spec) = @_;

    $spec->{dummy_option} = 0;

    return;
}

sub notify {
    my ($self, $params) = @_;

    return;
}

1;
