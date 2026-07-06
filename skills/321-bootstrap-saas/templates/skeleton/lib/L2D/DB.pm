# Copyright Nige Ltd. Author: Nigel Hamilton.
package L2D::DB;

#------------------------------------------------------------------------------
# Per-request database wrapper. Resolves a 'group/name' key to the SQL template
# sql/<group>/<name>.sql.ep, renders it, and executes it on this request's
# Mojo::Pg::Database. This is the engine documented by the 321-sql-template
# skill - read that skill for the full design and gotchas.
#------------------------------------------------------------------------------

use Mojo::Base -base, -signatures;

use L2D::DB::SQL;
use Mojo::File qw(path);

has 'db';           # Mojo::Pg::Database for this request
has 'sql_dir';      # path to the sql/ directory
has sql_renderer => sub { L2D::DB::SQL->new };

my %TEMPLATE_CACHE;

#------------------------------------------------------------------------------
# query - render the named SQL template and execute it. Returns a Mojo::Pg
#   results object (->hash, ->hashes->to_array, ->expand->hash, ...).
#------------------------------------------------------------------------------
sub query ($self, $name, $record = {}) {

    my $template     = $self->_load_template($name);
    my ($sql, $bind) = $self->sql_renderer->render($template, $record);

    return $self->db->query($sql, @$bind);
}

#------------------------------------------------------------------------------
# raw - direct passthrough for the rare non-template query.
#------------------------------------------------------------------------------
sub raw ($self, $sql, @bind) {
    return $self->db->query($sql, @bind);
}

#------------------------------------------------------------------------------
# _load_template - slurp sql/<group>/<name>.sql.ep, cached in-process.
#   The name regex is the path-traversal guard AND enforces the flat
#   group/name layout. Templates are cached forever: edits need a restart.
#------------------------------------------------------------------------------
sub _load_template ($self, $name) {

    return $TEMPLATE_CACHE{$name} if exists $TEMPLATE_CACHE{$name};

    die "Invalid SQL template name '$name'\n"
        unless $name =~ m{\A[a-z0-9_]+/[a-z0-9_]+\z};

    my $file = path($self->sql_dir, split m{/}, "$name.sql.ep");

    die "SQL template not found: $file\n" unless -f $file;

    return $TEMPLATE_CACHE{$name} = $file->slurp;
}

1;
