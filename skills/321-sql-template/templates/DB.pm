package F6::DB;

#------------------------------------------------------------------------------
# The resolver. Port this: rename the package (and the F6::DB::SQL use below)
# to your app's namespace. No changes needed beyond the names.
#
# Resolves 'group/name' to sql/<group>/<name>.sql.ep, renders it via
# F6::DB::SQL, and executes the parameterized result on this request's
# Mojo::Pg::Database.
#------------------------------------------------------------------------------

use Mojo::Base -base, -signatures;

use F6::DB::SQL;
use Mojo::File qw(path);

has 'db';           # Mojo::Pg::Database for this request
has 'sql_dir';      # path to the sql/ directory
has sql_renderer => sub { F6::DB::SQL->new };

my %TEMPLATE_CACHE;  # in-process, never expires -> edits need a restart

#------------------------------------------------------------------------------
# query - render the named SQL template and execute it
#------------------------------------------------------------------------------
sub query ($self, $name, $record = {}) {

    my $template      = $self->_load_template($name);
    my ($sql, $bind)  = $self->sql_renderer->render($template, $record);

    return $self->db->query($sql, @$bind);
}

#------------------------------------------------------------------------------
# raw - direct passthrough for the rare non-template query
#------------------------------------------------------------------------------
sub raw ($self, $sql, @bind) {

    return $self->db->query($sql, @bind);
}

#------------------------------------------------------------------------------
# _load_template - slurp sql/<group>/<name>.sql.ep, cached in-process.
# The name check both blocks '../' traversal and enforces the flat
# group/name layout (rejects deeper nesting like a/b/c).
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
