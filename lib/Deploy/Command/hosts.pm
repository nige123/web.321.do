package Deploy::Command::hosts;

use Mojo::Base 'Deploy::Command', -signatures;
use Deploy::Hosts;

has description => 'Update /etc/hosts with dev-target hostnames';
has usage => sub ($self) { $self->extract_usage };

sub run ($self, @args) {
    my $hosts = $self->config->dev_hostnames;

    if ($args[0] && $args[0] eq '--print') {
        say for @$hosts;
        return;
    }

    unless (-w '/etc/hosts') {
        die "\n  /etc/hosts needs sudo. Re-run:\n  sudo -E perl bin/321.pl hosts\n";
    }

    Deploy::Hosts->new->write($hosts);
    say "Wrote " . scalar(@$hosts) . " dev host(s) to /etc/hosts:";
    say "  $_" for @$hosts;
}

1;

=head1 SYNOPSIS

  Usage: APPLICATION hosts [--print]

  Writes /etc/hosts managed block from all services' dev-target hostnames.
  Use --print to preview without writing.
  Needs sudo for the actual write.

=cut
