package Deploy::Command::status;

use Mojo::Base 'Deploy::Command', -signatures;

has description => 'Show service status';
has usage => sub ($self) { $self->extract_usage };

sub run ($self, @args) {
    if (@args) {
        my $name = $self->resolve_service($args[0]);
        system("ubic status $name");
    } else {
        for my $name (@{ $self->config->service_names }) {
            my $out = `ubic status $name 2>&1`;
            chomp $out;
            printf "  %-20s %s\n", $name, $out;
        }
    }
}

1;

=head1 SYNOPSIS

  Usage: APPLICATION status [service]

  321 status            # all services
  321 status zorda.web  # single service

=cut
