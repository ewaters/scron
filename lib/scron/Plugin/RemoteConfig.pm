package scron::Plugin::RemoteConfig;

use strict;
use warnings;
use File::Path;
use Config::Simple;
use LWP;
use POE;
use Storable;
use base qw(scron::Plugin);

our $VERSION = 0.1;

my $ua = LWP::UserAgent->new();
$ua->agent(__PACKAGE__."/".$VERSION);

# Check every hour
#my $check_frequency = 30;
my $check_frequency = 1 * 60 * 60;

my $gpg_bin = '/usr/bin/gpg';

sub start {
    my ($self) = @_;

    POE::Session->create(
        object_states => [
            $self => [qw(
                _start
                _stop
                update_config
            )],
        ],
    );
}

sub _start {
    my ($kernel, $heap) = @_[KERNEL, HEAP];

    $kernel->alias_set(__PACKAGE__);

    $kernel->delay(update_config => $check_frequency);
}

sub stop {
    my $self = shift;

    $poe_kernel->post(__PACKAGE__, '_stop');
}

sub _stop {
    my ($kernel, $heap) = @_[KERNEL, HEAP];

    $kernel->alarm_remove_all();
}

## update_validate_spec ($block, $spec)
#
#  Standard plugin hook: given a block name and the Params::Validate spec, add
#  the keys that I support.

sub update_validate_spec {
    my ($self, $block, $spec) = @_;

    $spec->{remote_config_url} = 0;
    $spec->{remote_config_classes} = 0;
    $spec->{remote_config_gpg_keyring} = 0;
    $spec->{_from_remote_config} = 0;
    $spec->{_unverified_remote_config} = 0;

    return;
}

## modify_config ($config)
#
#  Standard plugin hook: given the servers' validated config, determine if I
#  should run and, if so, get the latest remote config, validate it, and load
#  it into the server.

sub modify_config {
    my ($self, $config) = @_;

    # First see if I will be used

    my $url = $config->{main}{remote_config_url};
    return unless $url;

    ## Set some instance vars for later

    # Generate a URL and store it for later
    $url .= '?hostname=' . $config->{main}{hostname};
    if (my $classes = $config->{main}{remote_config_classes}) {
        my @classes = ref $classes ? @$classes : ($classes);
        $url .= '&class=' . $_ foreach @classes;
    }
    $self->{url} = $url;

    my $cache_dir = $config->{main}{template_cache_dir};
    $cache_dir ||= '/var/cache/scron';
    my $cache_file = $cache_dir . '/remote_config.cache';
    $self->{cache_file} = $cache_file;

    $self->{gpg_keyring} = $config->{main}{remote_config_gpg_keyring};
    $self->{gpg_keyring} = undef unless -f $self->{gpg_keyring};

    # Get the latest config
    
    my ($latest, $from_cache);
    eval {
        ($latest, $from_cache) = $self->get_latest_config();
    };
    if ($@) {
        $self->logger->error("Failed to get latest config: $@");
        return;
    }
    if (! $latest) {
        return;
    }
    if ($from_cache) {
        $self->logger->debug("Using cached remote config");
    }
    else {
        $self->logger->debug("Using live remote config");
    }

    # Create new config blocks and validate them

    my %new;
    my $default = delete $latest->{default} || {};
    foreach my $block (keys %$latest) {
        $new{$block} = {
            %$default,
            %{ $latest->{$block} },
            _from_remote_config => 1,
        };
    }

    my $is_valid = main::validate_config(\%new);
    return unless $is_valid;

    # Incorporate into master config

    foreach my $block (keys %new) {
        if ($config->{$block} && ! exists $config->{$block}{_from_remote_config}) {
            $self->logger->error("RemoteConfig attempted to rewrite '$block', which didn't come from RemoteConfig");
            next;
        }
        else {
            $self->logger->debug("Adding '$block' from remote config");
        }
        $config->{$block} = $new{$block};
    }

    return;
}

## update_config ()
#
#  Called frequently to check if the remote config has changed and, if so,
#  reload the server.

sub update_config {
    my ($self, $kernel, $heap) = @_[OBJECT, KERNEL, HEAP];

    return if ! $self->{url};

    my ($config, $from_cache);
    eval {
        ($config, $from_cache) = $self->get_latest_config;
    };
    if ($@) {
        $self->logger->error("Failed to get latest config: $@");
    }
    if ($config && ! $from_cache) {
        $self->logger->info("Remote config changed (and cached); reloading server");
        $kernel->post(scrond => 'reload');
        return;
    }

    $kernel->delay(update_config => $check_frequency);
}

## get_latest_config ()
#
#  Retrieve the latest config from the URL in the settings.  Permit offline
#  operations: if we've retrieved the config before and the URL is unreachable,
#  or if the URL has some sort of error, use the cached copy.

sub get_latest_config {
    my $self = shift;

    my $cached;
    if (-f $self->{cache_file}) {
        eval {
            $cached = retrieve($self->{cache_file});
        };
        if ($@ || ! defined $cached) {
            $self->logger->error("Failed to load cache file $cached: $@");
        }
    }

    my $head_etag;
    while (1) {
        my $head_response = $ua->head($self->{url});
        if (! $head_response->is_success) {
            $self->logger->error("Failed to get $$self{url}: " . $head_response->status_line);
            last;
        }
        $head_etag = $head_response->header('ETag');
        if (! $head_etag) {
            $self->logger->error("No 'ETag' on $$self{url}");
            last;
        }
        last;
    }

    # Check if we want to use the cached config
    if ($cached && (! defined $head_etag || $cached->{etag} eq $head_etag)) {
        return wantarray ? ($cached->{config}, 1) : $cached->{config};
    }

    if (! $head_etag) {
        $self->logger->error("Couldn't communicate with RemoteConfig server, and no cached copy to use as failover");
        return;
    }

    ## Not using the cache; get a new copy

    -f $self->{cache_file} && unlink $self->{cache_file};

    my $get_response = $ua->get($self->{url});
    if (! $get_response->is_success) {
        $self->logger->error("Failed to get $$self{url}: " . $get_response->status_line);
        return;
    }

    my $content = $get_response->content;
    my %parsed;
    
    my @blocks = $content =~ m{<config>(.+?)</config>}sg;
    foreach my $content_block (@blocks) {
        my ($data, $sig) = $content_block =~ m{^<data>(.+)</data><sig>(.*)</sig>$}sm;
        if (! $data) {
            $self->logger->error("Invalid syntax from $$self{url}: no <data/>");
            return;
        }

        if ($sig && $self->{gpg_keyring}) {
            my $is_valid = $self->validate_gpg_signature($data, $sig);
            if (! $is_valid) {
                $self->logger->error("Invalid GPG signature on config block");
                next;
            }
        }

        my $parsed = $self->parse_config($data);
        next unless $parsed;

        foreach my $key (keys %$parsed) {
            my $block = $parsed->{$key};
            if (! $sig) {
            # Only allow signed blocks to run setuid/gid
                $block->{user} = 'nobody';
                $block->{group} = 'nogroup';
                $block->{_unverified_remote_config} = 1;
            }
            $parsed{$key} = $block;
        }
    }
    
    # Cache it for later

    $cached = {
        etag => $get_response->header('ETag'),
        config => \%parsed,
    };
    store $cached, $self->{cache_file};
    chmod 0600, $self->{cache_file};

    return wantarray ? ($cached->{config}, 0) : $cached->{config};
}

## parse_config ($data)
#
#  Given an in memory config block, parse it and return the proper data
#  structure.  Config::Simple appears to not support in memory parsing, so we
#  must write it out to file.

sub parse_config {
    my ($self, $data) = @_;

    my $tmp_fn = tmp_file_dump($data);
    my $cfg = Config::Simple->new($tmp_fn);
    unlink $tmp_fn;

    if (! $cfg) {
        $self->logger->error("Couldn't parse '$tmp_fn'");
        return;
    }

    my %parsed;

    my $hash = $cfg->vars();
    while (my ($key, $value) = each %$hash) {
        my ($block, $param) = $key =~ /^(.+)\.([^.]+)$/;
        if (! $param) {
            $self->logger->error("Couldn't parse $$self{url} configuration key '$key'");
            next;
        }
        $parsed{$block}{$param} = $value;
    }

    return \%parsed;
}

## validate_gpg_signature ($data, $signature)
#
#  Use the CLI gpg tool to validate $data with the signature $signature.
#  gpg doesn't appear to allow for piped input, so we write out two files and
#  call gpg to do perform the verify.

sub validate_gpg_signature {
    my ($self, $data, $signature) = @_;

    my $data_fn = tmp_file_dump($data);
    my $sig_fn  = tmp_file_dump($signature, $data_fn . '.sig');
    my $homedir = tmp_dir();

    system "$gpg_bin --homedir $homedir --no-permission-warning --no-options --no-default-keyring "
        ."--keyring $$self{gpg_keyring} --quiet --verify $sig_fn > /dev/null 2>&1";

    unlink $data_fn;
    unlink $sig_fn;
    system 'rm', '-rf', $homedir;
    
    if ($? == -1) {
        die "Failed to run gpg --verify: $!";
    }
    my $exit_value = $? >> 8;
    return $exit_value == 0 ? 1 : 0;
}

## tmp_file_dump ($data, [ $filename ])
#
#  Dumps $data to a temporary file.  If filename is provided, use that,
#  otherwise come up with a tmp file on your own.

sub tmp_file_dump {
    my ($data, $tmp_fn) = @_;

    $tmp_fn ||= "/tmp/scron.readconfig.".int(rand(1000))."-$$-".time;
    -f $tmp_fn && die "Temp file $tmp_fn already exists";

    local $/ = undef;
    open my $out, '>', $tmp_fn or die;
    print $out $data;
    close $out;

    return $tmp_fn;
}

sub tmp_dir {
    my $dir = "/tmp/scron.readconfig.".int(rand(1000))."-$$-".time.'.d';
    mkdir $dir;
    return $dir;
}

1;
