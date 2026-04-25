package Deploy::Command::status;

use Mojo::Base 'Deploy::Command', -signatures;

has description => 'Show service status';
has usage => sub ($self) { $self->extract_usage };

sub run ($self, @args) {
    my ($svc_input, $target) = $self->parse_target(@args);
    $self->config->target($target);

    my @names = $svc_input
        ? ($self->resolve_service($svc_input))   # list context: returns all matches
        : @{ $self->config->service_names };

    for my $name (@names) {
        my $svc = $self->config->service($name);
        my $transport = $self->transport_for($name, $target);

        # Ubic status
        my $r = $transport->run("ubic status $name");
        my $ubic_status = $r->{output} // '';
        chomp $ubic_status;
        $ubic_status =~ s/^.*?\t//;
        $ubic_status =~ s/^\Q$name\E\s+//;

        my $port = $svc->{port} // '?';
        my $url  = $self->service_url($svc);

        # Port check — only when ubic says running (skip extra round-trip for stopped services)
        my $ubic_says_running = $ubic_status =~ /running/;
        my $port_ok = $ubic_says_running ? $self->check_port($port, $transport) : 0;

        my $actually_running = $ubic_says_running && $port_ok;
        my $status_text;
        if ($actually_running) {
            $status_text = "\e[32m$ubic_status\e[0m";
        } elsif ($ubic_says_running && !$port_ok) {
            $status_text = "\e[33m$ubic_status (port $port not responding)\e[0m";
        } else {
            $status_text = "\e[31m$ubic_status\e[0m";
        }

        printf "%-15s  %s  port:%-5s  %s\n", $name, $status_text, $port, $url;

        if ($ubic_says_running && !$port_ok) {
            my $flag = $self->target_flag($target);
            say "               \e[33m^\e[0m process alive but not serving — try: 321 restart $name$flag";
        } elsif (!$ubic_says_running && $ubic_status =~ /off|not running/) {
            my $flag = $self->target_flag($target);
            say "               \e[31m^\e[0m start with: 321 start $name$flag";
        }
    }
}

1;

=head1 SYNOPSIS

  Usage: APPLICATION status [service]

  321 status            # all services
  321 status zorda.web  # single service

=cut
