package F6::DB::SQL;

#------------------------------------------------------------------------------
# The renderer. Port this: rename the package to your app's namespace.
#
# Two layers:
#   1. Mojo::Template renders the .sql.ep (dynamic logic: <% if %>, ranges).
#   2. A [name] -> ? pass collects binds in order (injection-safe values).
#------------------------------------------------------------------------------

use Mojo::Base -base, -signatures;

use Mojo::Template;

has 'template' => sub {
    return Mojo::Template->new(
        # vars => 1 lets templates reference $record fields directly, but
        # Mojo::Template then treats a bare '@' as the start of a Perl array
        # variable. SQL strings containing '@' MUST escape it as '\@'.
        vars        => 1,
        auto_escape => 0,   # emitting SQL, not HTML
    );
};

#------------------------------------------------------------------------------
# render - render a SQL template string and extract bind parameters.
# Returns ($sql, \@bind).
#------------------------------------------------------------------------------
sub render ($self, $sql_template, $record = {}) {

    my $sql = $self->template->render($sql_template, $record);

    chomp $sql;

    my @bind;
    my $used = {};

    # Each [name] OCCURRENCE becomes its own ? with its own pushed value,
    # so a name repeated N times binds N times, in source order.
    $sql =~ s{
        \[([a-zA-Z_][a-zA-Z0-9_]*)\]
    }{
        my $field = $1;

        die "Missing bind parameter [$field]"
            unless exists $record->{$field};

        push @bind, $record->{$field};
        $used->{$field} = 1;

        '?'
    }gex;

    # Warn on binds passed but never used - usually a typo in the SQL.
    # (undef values are skipped: they're legitimately-optional params.)
    foreach my $field (sort keys %$record) {
        next if $used->{$field};
        next unless defined $record->{$field};
        warn "F6::DB::SQL warning: unused bind parameter [$field]\n";
    }

    return ($sql, \@bind);
}

1;
