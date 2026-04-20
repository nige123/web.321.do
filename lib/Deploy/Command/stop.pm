package Deploy::Command::stop;

use Mojo::Base 'Deploy::Command', -signatures;

has description => 'Stop a service';
has usage => sub ($self) { $self->extract_usage };

sub run ($self, @args) {
    my ($svc_input, $target) = $self->parse_target(@args);
    die $self->usage unless $svc_input;
    my $name = $self->resolve_service($svc_input);
    my $transport = $self->transport_for($name, $target);
    $self->config->target($target);
    my $r = $transport->run("ubic stop $name");
    if ($r->{ok}) {
        say "  $name stopped ($target)";
    } else {
        say "  $name stop failed: $r->{output}";
    }
}

1;

=head1 SYNOPSIS

  Usage: APPLICATION stop <service>

=cut
