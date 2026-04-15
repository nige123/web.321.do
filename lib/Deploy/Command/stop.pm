package Deploy::Command::stop;

use Mojo::Base 'Deploy::Command', -signatures;

has description => 'Stop a service';
has usage => sub ($self) { $self->extract_usage };

sub run ($self, @args) {
    die $self->usage unless @args;
    my $name = $self->resolve_service($args[0]);
    say "Stopping $name";
    $self->run_cmd("ubic stop $name");
}

1;

=head1 SYNOPSIS

  Usage: APPLICATION stop <service>

=cut
