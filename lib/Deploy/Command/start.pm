package Deploy::Command::start;

use Mojo::Base 'Deploy::Command', -signatures;

has description => 'Start a service';
has usage => sub ($self) { $self->extract_usage };

sub run ($self, @args) {
    die $self->usage unless @args;
    my $name = $self->resolve_service($args[0]);
    say "Starting $name";
    $self->run_cmd("ubic start $name");
}

1;

=head1 SYNOPSIS

  Usage: APPLICATION start <service>

=cut
