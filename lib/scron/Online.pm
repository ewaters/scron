package scron::Online::Model::Job;

use strict;
use warnings;

use base qw/DBIx::Class/;

__PACKAGE__->load_components(qw/Core/);
__PACKAGE__->table('job');
__PACKAGE__->add_columns(
    id    => { data_type => 'CHAR', size => 22, },
    name  => { data_type => 'VARCHAR', size => 128, },
    param => { data_type => 'TEXT', }, 
);
__PACKAGE__->set_primary_key('id');

__PACKAGE__->has_many(Instances => 'scron::Online::Model::Instance',
    { 'foreign.job_id' => 'self.id' });

__PACKAGE__->inflate_column('param', {
    inflate => \&scron::dumper_inflate,
    deflate => \&scron::dumper_deflate,
});

package scron::Online::Model::Host;

use strict;
use warnings;

use base qw/DBIx::Class/;

__PACKAGE__->load_components(qw/Core/);
__PACKAGE__->table('host');
__PACKAGE__->add_columns(
    id    => { data_type => 'CHAR', size => 22, },
    name  => { data_type => 'VARCHAR', size => 128, },
);
__PACKAGE__->set_primary_key('id');

__PACKAGE__->has_many(Instances => 'scron::Online::Model::Instance',
    { 'foreign.host_id' => 'self.id' });

package scron::Online::Model::Instance;

use strict;
use warnings;

use base qw/DBIx::Class/;

__PACKAGE__->load_components(qw/Core/);
__PACKAGE__->table('instance');
__PACKAGE__->add_columns(
    id      => { data_type => 'CHAR', size => 22, },
    job_id  => { data_type => 'CHAR', size => 22, },
    host_id => { data_type => 'CHAR', size => 22, },
    start   => { data_type => 'DATETIME', is_nullable => 0, },
    finish  => { data_type => 'DATETIME', is_nullable => 1, },
    disposition => { data_type => 'TINYINT', is_nullable => 1, extras => { unsigned => 1 }, },
);
__PACKAGE__->set_primary_key('id');

__PACKAGE__->belongs_to(Job => 'scron::Online::Model::Job',
    { 'foreign.id' => 'self.job_id' });
__PACKAGE__->belongs_to(Host => 'scron::Online::Model::Host',
    { 'foreign.id' => 'self.host_id' });

__PACKAGE__->has_many(Events => 'scron::Online::Model::Event',
    { 'foreign.instance_id' => 'self.id' });
__PACKAGE__->has_many(StatValues => 'scron::Online::Model::InstanceStatValue',
    { 'foreign.instance_id' => 'self.id' });

package scron::Online::Model::InstanceStatValue;

use strict;
use warnings;

use base qw/DBIx::Class/;

__PACKAGE__->load_components(qw/Core/);
__PACKAGE__->table('instancestatvalue');
__PACKAGE__->add_columns(
    instance_id          => { data_type => 'CHAR', size => 22, },
    instance_stat_key_id => { data_type => 'TINYINT', is_nullable => 0, extra => { unsigned => 1 }, },
    value                => { data_type => 'FLOAT',   is_nullable => 0, },
);
__PACKAGE__->set_primary_key('instance_id', 'instance_stat_key_id');

__PACKAGE__->belongs_to(Instance => 'scron::Online::Model::Instance',
    { 'foreign.id' => 'self.instance_id' });

package scron::Online::Model::Event;

use strict;
use warnings;

use base qw/DBIx::Class/;

__PACKAGE__->load_components(qw/Core/);
__PACKAGE__->table('event');
__PACKAGE__->add_columns(
    instance_id => { data_type => 'CHAR', size => 22, },
    offset      => { data_type => 'FLOAT',   is_nullable => 0, },
    type        => { data_type => 'TINYINT', extras => { unsigned => 1 }, },
    details     => { data_type => 'TINYTEXT', },
);
__PACKAGE__->set_primary_key('instance_id', 'offset');

__PACKAGE__->belongs_to(Instance => 'scron::Online::Model::Instance',
    { 'foreign.id' => 'self.instance_id' });

package scron::Online::Model;

use strict;
use warnings;

use base qw/DBIx::Class::Schema/;
__PACKAGE__->load_classes(qw/Job Host Instance InstanceStatValue Event/);

1;
