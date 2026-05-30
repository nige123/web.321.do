package Deploy::Command::restart;

use Mojo::Base 'Deploy::Command', -signatures;

has description => 'Restart a service';
has usage => sub ($self) { $self->extract_usage };

sub run ($self, @args) {
    my ($svc_input, $target) = $self->parse_target(@args);
    die $self->usage unless $svc_input;
    my @names = $self->resolve_service($svc_input);
    $self->config->target($target);

    for my $name (@names) {
        my $transport = $self->transport_for($name, $target);
        $self->ensure_fresh_ubic($name, $transport);
        my $svc_mgr = $self->svc_mgr;
        $svc_mgr->transport($transport);
        my $r = $svc_mgr->restart($name);
        $self->print_steps($r);
        if ($r->{status} eq 'success') {
            my $svc  = $self->config->service($name);
            my $port = $svc->{port} // '?';
            my $url  = $self->service_url($svc);
            say "  $r->{message}  port:$port  $url";

            # Cascade worker restarts after main succeeded. No-op when
            # $name is a worker or has no workers.
            for my $row (@{ $self->cascade_workers($name, 'restart', $transport) }) {
                $self->print_worker_step('restart', $row);
            }
        } else {
            $self->print_failure($transport, $name, $target, $r->{message});
        }
    }
}

1;

=head1 SYNOPSIS

  Usage: APPLICATION restart <service>

  Restarts the named service. When the name is a main with workers
  declared in 321.yml, every worker is restarted (ubic restart) after
  the main restart succeeds. Naming a worker directly restarts only
  that worker.

=cut
