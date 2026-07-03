package L2D::DB::SQL;

#------------------------------------------------------------------------------
# Runtime SQL template renderer. Two layers: (1) Mojo::Template renders the file
# (so authors get <% if %> for optional clauses), then (2) a [bind] pass
# rewrites each [name] to a `?` and collects the value — so the driver
# parameterizes it and injection is impossible. Documented by 321-sql-template.
#------------------------------------------------------------------------------

use Mojo::Base -base, -signatures;

use Mojo::Template;
use Mojo::File qw(path);

has 'template' => sub {
    return Mojo::Template->new(
        # vars => 1 lets templates reference $record fields directly, but
        # Mojo::Template then treats a bare '@' as a Perl array sigil. SQL
        # strings containing '@' MUST escape it as '\@'.
        vars        => 1,
        auto_escape => 0,
    );
};

#------------------------------------------------------------------------------
# render - render a SQL template string and extract bind parameters in order.
#   A [name] with no matching key DIES (a real bug you want immediately); a
#   passed key never referenced only WARNS (likely a typo).
#------------------------------------------------------------------------------
sub render ($self, $sql_template, $record = {}) {

    my $sql = $self->template->render($sql_template, $record);

    chomp $sql;

    my @bind;
    my $used = {};

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

    foreach my $field (sort keys %$record) {
        next if $used->{$field};
        next unless defined $record->{$field};
        warn "L2D::DB::SQL warning: unused bind parameter [$field]\n";
    }

    return ($sql, \@bind);
}

#------------------------------------------------------------------------------
# render_file - render a SQL template loaded from a file.
#------------------------------------------------------------------------------
sub render_file ($self, $file, $record = {}) {
    my $template = path($file)->slurp;
    return $self->render($template, $record);
}

1;
