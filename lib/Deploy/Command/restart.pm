package Deploy::Command::restart;

use Mojo::Base 'Deploy::Command', -signatures;

has description => 'Restart a service';
has usage => sub ($self) { $self->extract_usage };

sub run ($self, @args) {
    die $self->usage unless @args;
    my $name = $self->resolve_service($args[0]);
    say "Restarting $name";
    $self->run_cmd("ubic restart $name");
}

1;

=head1 SYNOPSIS

  Usage: APPLICATION restart <service>

=cut
