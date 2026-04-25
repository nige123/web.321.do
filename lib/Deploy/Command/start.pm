package Deploy::Command::start;

use Mojo::Base 'Deploy::Command', -signatures;

has description => 'Start a service';
has usage => sub ($self) { $self->extract_usage };

sub run ($self, @args) {
    my ($svc_input, $target) = $self->parse_target(@args);
    die $self->usage unless $svc_input;
    my @names = $self->resolve_service($svc_input);
    $self->config->target($target);

    for my $name (@names) {
        $self->_start_one($name, $target);
    }

    # Show status
    say "";
    require Deploy::Command::status;
    Deploy::Command::status->new(app => $self->app)->run($svc_input, $target);
}

sub _start_one ($self, $name, $target) {
    my $transport = $self->transport_for($name, $target);
    my $svc  = $self->config->service($name);
    my $port = $svc->{port} // '?';
    my $url  = $self->service_url($svc);

    # Already running?
    my $status = $transport->run("ubic status $name 2>&1");
    if ($status->{ok} && $status->{output} =~ /running \(pid (\d+)\)/) {
        say "  \e[32m$name is already running\e[0m  pid:$1  port:$port  $url";
        return;
    }

    # Check if port is taken by something else
    if ($port && $port ne '?' && $self->check_port($port, $transport)) {
        my $who = $transport->run("ss -tlnp | grep ':$port '");
        say "  \e[31m$name: port $port is already in use\e[0m";
        say "  $who->{output}" if $who->{output} && $who->{output} =~ /\S/;
        return;
    }

    my $r = $transport->run("ubic start $name");

    if ($r->{output} && $r->{output} =~ /not found|unknown service/i) {
        say "  \e[31m$name is not installed\e[0m — run: 321 install $name" . $self->target_flag($target);
        return;
    }

    say "  $r->{output}" if $r->{output} && $r->{output} =~ /\S/;

    sleep 2;
    my $port_ok = $self->check_port($port, $transport);

    if ($port_ok) {
        say "  \e[32m$name running\e[0m ($target)  port:$port  $url";
    } else {
        say "  \e[31m$name not running\e[0m after start";
        $self->print_failure($transport, $name, $target);
    }
}

1;

=head1 SYNOPSIS

  Usage: APPLICATION start <service>

=cut
