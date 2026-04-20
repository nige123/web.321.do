package Deploy::Command::rebuild;

use Mojo::Base 'Deploy::Command', -signatures;
use Deploy::Hosts;

has description => 'Regenerate all ubic service files';
has usage => sub ($self) { $self->extract_usage };

sub run ($self, @args) {
    my (undef, $target) = $self->parse_target(@args);

    say "Rebuilding ubic service files ($target)...";

    my $ubic = $self->ubic;
    $ubic->generate_all;

    say "Done.";

    if ($target eq 'dev') {
        my $dev_hosts = $self->config->dev_hostnames;
        if (@$dev_hosts && -w '/etc/hosts') {
            Deploy::Hosts->new->write($dev_hosts);
            say "  /etc/hosts updated (" . scalar(@$dev_hosts) . " dev hosts)";
        } elsif (@$dev_hosts) {
            say "  /etc/hosts not writable - run 'sudo -E perl bin/321.pl hosts' to update";
        }
    }
}

1;

=head1 SYNOPSIS

  Usage: APPLICATION rebuild [target]

  Regenerates all ubic service files from config and reinstalls symlinks.

=cut
