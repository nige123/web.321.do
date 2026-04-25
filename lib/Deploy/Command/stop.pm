package Deploy::Command::stop;

use Mojo::Base 'Deploy::Command', -signatures;

has description => 'Stop a service';
has usage => sub ($self) { $self->extract_usage };

sub run ($self, @args) {
    my ($svc_input, $target) = $self->parse_target(@args);
    die $self->usage unless $svc_input;
    my @names = $self->resolve_service($svc_input);
    $self->config->target($target);

    for my $name (@names) {
        my $transport = $self->transport_for($name, $target);
        my $r = $transport->run("ubic stop $name");
        if ($r->{ok}) {
            say "  $name stopped ($target)";
        } else {
            say "  $name stop failed: $r->{output}";
        }
    }

    # Show status
    say "";
    require Deploy::Command::status;
    Deploy::Command::status->new(app => $self->app)->run($svc_input, $target);
}

1;

=head1 SYNOPSIS

  Usage: APPLICATION stop <service>

=cut
