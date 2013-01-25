#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use Term::ReadLine;
use File::Copy;
use File::Path;

## Configure

my $gpg_public_keyring = $FindBin::Bin . '/../keys/public';
my $gpg_private_keyring = $FindBin::Bin . '/../keys/private';

my $fn = $ARGV[0];

## Setup

my $gpg_sign_cmd = "/usr/bin/gpg --no-options --no-default-keyring "
    ."--keyring $gpg_public_keyring --secret-keyring $gpg_private_keyring "
    ."--quiet --detach-sign --sign";
my $term = Term::ReadLine->new('default');

my $create;
if (! -f $fn) {
    my $answer = ask_question("File doesn't exist.  Create?", qw(Yes no));
    exit if $answer eq 'no';
    $create = 1;
}

# Copy to a temporary location

my $tmp_fn = "/tmp/edit_signed_config-".int(rand(1000)).'-'.$$.'.tmp.ini';
if (! $create) {
    copy($fn, $tmp_fn) or die "Couldn't copy $fn -> $tmp_fn: $!";
}

while (1) {
    system 'editor', $tmp_fn;
    my $answer = ask_question("Sign, Edit, or Quit?", qw(Sign edit quit));
    next if $answer eq 'edit';
    cleanup() if $answer eq 'quit';
    last if $answer eq 'sign';
}

while (1) {
    system $gpg_sign_cmd . ' ' . $tmp_fn;
    if (! -f $tmp_fn . '.sig') {
        my $answer = ask_question("Failed to sign; try again?", qw(yes No));
        cleanup() if $answer eq 'no';
        next;
    }
    last;
}

my %moves = (
    $tmp_fn => $fn,
    $tmp_fn . '.sig' => $fn . '.sig',
);

while (my ($from, $to) = each %moves) {
    if (! -f $from) {
        die "No such file '$from' for move to '$to'";
    }

    my ($base_path) = $from =~ m{^(.+)/[^/]+$};
    -d $base_path || mkpath( $base_path, { verbose => 0 } ) || die "Can't make path '$base_path': $!";

    system 'mv', '-f', $from, $to;
    if (! -f $to) {
        die "Failed to move '$from' to '$to'";
    }
}

print "Successfully edited and signed $fn!\n";

cleanup();

## Utilities

sub cleanup {
    unlink $tmp_fn if -f $tmp_fn;;
    unlink $tmp_fn . '.sig' if -f $tmp_fn . '.sig';
    exit;
}

sub ask_question {
    my ($question, @responses) = @_;

    @responses = ('Yes') if ! @responses;

    my (@chars, %chars, $default);
    foreach my $response (@responses) {
        my $char = substr $response, 0, 1;
        if ($chars{lc $char}) {
            die "More than one response with the same first initial";
        }
        $chars{lc $char} = lc $response;
        push @chars, $char;
        $default = lc $response if $char =~ /[A-Z]/;
    }

    my ($response);
    while (1) {
        my $action = $term->readline("$question [".join('/', @chars)."] ");
        if (! defined $action || length $action == 0) {
            $response = $default;
            last;
        }
        
        ($response) = grep { $_ =~ /^$action/i } @responses;
        if (! $response) {
            print "Response should be in: ".join(', ', @responses)." (you said '$action')\n";
            next;
        }
        last;
    }

    #print STDERR "response was '$response'\n";

    return lc $response;
}
