package Deploy::Command::start;

use Mojo::Base 'Deploy::Command', -signatures;

has description => 'Start a service';
has usage => sub ($self) { $self->extract_usage };

sub run ($self, @args) {
    return $self->_start_all if @args == 1 && lc $args[0] eq 'all';

    my ($svc_input, $target) = $self->parse_target(@args);
    die $self->usage unless $svc_input;
    my @names = $self->resolve_service($svc_input);
    $self->config->target($target);

    for my $name (@names) {
        my $transport = $self->transport_for($name, $target);
        $self->_start_with_workers($name, $target, $transport);
    }

    $self->_show_status($svc_input, $target);
}

# Start every local service (the dev target), each cascading to its workers.
# Live-only services are deliberately left alone.
sub _start_all ($self) {
    my $target = 'dev';
    $self->config->target($target);
    say "Starting all local services ($target)...";
    say "";
    for my $name (@{ $self->local_main_services }) {
        my $transport = $self->transport_for($name, $target);
        $self->_start_with_workers($name, $target, $transport);
    }
    $self->_show_status(undef, $target);
}

# Start a main, then cascade to its workers only if the main came up. No-op
# cascade when $name is a worker or has no workers.
sub _start_with_workers ($self, $name, $target, $transport) {
    my $up = $self->_start_one($name, $target, $transport);
    return unless $up;
    for my $w (@{ $self->config->workers_of($name) }) {
        $self->_start_one($w, $target, $transport);
    }
}

sub _show_status ($self, $svc_input, $target) {
    say "";
    require Deploy::Command::status;
    Deploy::Command::status->new(app => $self->app)->run($svc_input, $target);
}

# Start one service. Returns 1 if the service ended up running (already
# running OR a fresh start succeeded and the port responded). Returns 0
# otherwise. Workers have no port; treat them as up if ubic reports running.
sub _start_one ($self, $name, $target, $transport) {
    $transport //= $self->transport_for($name, $target);
    $self->ensure_fresh_ubic($name, $transport);
    my $svc  = $self->config->service($name);
    my $port = $svc->{port} // '?';
    my $url  = $self->service_url($svc);

    my $status = $transport->run("ubic status $name 2>&1");
    if ($status->{ok} && $status->{output} =~ /running \(pid (\d+)\)/) {
        say "  \e[32m$name is already running\e[0m  pid:$1  port:$port  $url";
        return 1;
    }

    if ($port && $port ne '?' && $self->check_port($port, $transport)) {
        my $who = $transport->run("ss -tlnp | grep ':$port '");
        say "  \e[31m$name: port $port is already in use\e[0m";
        say "  $who->{output}" if $who->{output} && $who->{output} =~ /\S/;
        return 0;
    }

    my $r = $transport->run("ubic start $name");

    if ($r->{output} && $r->{output} =~ /not found|unknown service/i) {
        say "  \e[31m$name is not installed\e[0m - run: 321 install $name" . $self->target_flag($target);
        return 0;
    }

    say "  $r->{output}" if $r->{output} && $r->{output} =~ /\S/;

    sleep 2;
    my $port_ok = ($svc->{is_worker} || !$port || $port eq '?')
        ? 1
        : $self->check_port($port, $transport);

    if ($port_ok) {
        say "  \e[32m$name running\e[0m ($target)" . ($port ne '?' ? "  port:$port" : '') . "  $url";
        return 1;
    } else {
        say "  \e[31m$name not running\e[0m after start";
        $self->print_failure($transport, $name, $target);
        return 0;
    }
}

1;

=head1 SYNOPSIS

  Usage: APPLICATION start <service>
         APPLICATION start all

  Starts the named service. When the name is a main with workers
  declared in 321.yml, every worker is started after the main comes
  up. Naming a worker directly starts only that worker.

  `start all` starts every local (dev-target) service, each cascading
  to its workers. Live-only services are never touched.

=cut
