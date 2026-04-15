package Deploy::Command::generate;

use Mojo::Base 'Deploy::Command', -signatures;

has description => 'Regenerate ubic service files';
has usage => sub ($self) { $self->extract_usage };

sub run ($self, @args) {
    my $results = $self->ubic->generate_all;
    for my $r (@$results) {
        say "  $r->{name}: $r->{path}";
    }
    my $links = $self->ubic->install_symlinks;
    for my $l (@$links) {
        say "  symlink: $l->{dest} -> $l->{source}";
    }
    say "Done.";
}

1;

=head1 SYNOPSIS

  Usage: APPLICATION generate

  Regenerate all ubic service files from config.

=cut
