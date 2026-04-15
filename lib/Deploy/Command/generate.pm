package Deploy::Command::generate;

use Mojo::Base 'Deploy::Command', -signatures;
use Deploy::Hosts;

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
    # Update /etc/hosts dev block (best-effort — skip if no sudo, warn but don't fail)
    my $dev_hosts = $self->config->dev_hostnames;
    if (@$dev_hosts && -w '/etc/hosts') {
        my $ok = eval { Deploy::Hosts->new->write($dev_hosts); 1 };
        if ($ok) {
            say "  /etc/hosts updated (" . scalar(@$dev_hosts) . " dev hosts)";
        } else {
            warn "  /etc/hosts update failed: $@";
        }
    } elsif (@$dev_hosts) {
        say "  /etc/hosts not writable - run 'sudo -E perl bin/321.pl hosts' to update";
    }
    say "Done.";
}

1;

=head1 SYNOPSIS

  Usage: APPLICATION generate

  Regenerate all ubic service files from config.

=cut
