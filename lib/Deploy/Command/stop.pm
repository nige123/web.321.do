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

        # Stop workers first (reverse sorted) so they settle before the main
        # process exits. No-op when $name resolves to a worker or to a main
        # with no workers — cascade_workers returns [] in those cases.
        for my $row (@{ $self->cascade_workers($name, 'stop', $transport) }) {
            $self->print_worker_step('stop', $row);
        }

        my $r = $transport->run("ubic stop $name");
        if ($r->{ok}) {
            say "  $name stopped ($target)";
        } else {
            say "  $name stop failed: $r->{output}";
        }
    }

    $self->_show_status($svc_input, $target);
}

sub _show_status ($self, $svc_input, $target) {
    say "";
    require Deploy::Command::status;
    Deploy::Command::status->new(app => $self->app)->run($svc_input, $target);
}

1;

=head1 SYNOPSIS

  Usage: APPLICATION stop <service>

  Stops the named service. When the name is a main service with workers
  declared in its 321.yml, workers are stopped first (reverse sorted),
  then the main. Naming a worker directly stops only that worker.

=cut
