use Module::Build;

BEGIN {
    eval 'use Module::Build::Debian';
}

my $build = Module::Build->new(
    module_name => 'scron',
    license => 'perl',
    requires => {
        'Config::Simple' => 0,
        'DateTime' => 0,
        'Log::Log4perl' => 0,
        'POE' => 0,
        'Params::Validate' => 0,
        'Class::Accessor' => 0,
        'POE::Component::Cron' => 0,
        'Log::Dispatch' => 0,
        'Proc::PID::File' => 0,
        'Proc::Daemon' => 0,
        'YAML' => 0,
        'DBIx::Class' => 0,
        'LWP' => 0,
        'SQL::Translator' => 0,
        'HTML::Mason' => 0,
        'Email::Sender' => 0,
        'Email::MIME::Creator' => 0,
    },
    recommends => {
    },
    #sign => 1,
    create_makefile_pl => 'passthrough',
    #create_readme => 1,
    install_path => {
        conf   => '/etc/scron',
        script => '/usr/sbin',
    },
    script_files => [
        'bin/scrond',
    ],
    conf_files => {
        'bin/scron.ini'       => 'conf/config.ini',
        'bin/config.d/README' => 'conf/config.d/README',

        'keys/public'         => 'conf/remote_config.keyring',

        'templates/autohandler'               => 'conf/templates/autohandler',
        'templates/completed_with_errors.mas' => 'conf/templates/completed_with_errors.mas',
        'templates/time_exceeded.mas'         => 'conf/templates/time_exceeded.mas',
    },
);

$build->add_build_element('conf');

$build->create_build_script;
