package Deploy::Command::start;

use Mojo::Base 'Deploy::Command', -signatures;

has description => 'Start a service';
has usage => sub ($self) { $self->extract_usage };

sub run ($self, @args) {
    my ($svc_input, $target) = $self->parse_target(@args);
    die $self->usage unless $svc_input;
    my $name = $self->resolve_service($svc_input);
    my $transport = $self->transport_for($name, $target);
    $self->config->target($target);
    my $r = $transport->run("ubic start $name");

    # Check if ubic knows about this service
    if ($r->{output} && $r->{output} =~ /not found|unknown service/i) {
        say "  \e[31m$name is not installed\e[0m";
        say "";
        say "  Next: install it first:";
        say "    321 install $name" . ($target ne 'dev' ? " $target" : "");
        return;
    }

    say "  $r->{output}" if $r->{output} && $r->{output} =~ /\S/;

    # Verify it's actually running
    sleep 1;
    my $check = $transport->run("ubic status $name");
    my $running = $check->{output} && $check->{output} =~ /running/;

    my $svc  = $self->config->service($name);
    my $port = $svc->{port} // '?';
    my $host = $svc->{host} // 'localhost';
    my $url  = $host ne 'localhost' ? "https://$host/" : "http://localhost:$port/";

    if ($running) {
        say "  \e[32m$name running\e[0m ($target)  port:$port  $url";
    } else {
        say "  \e[31m$name not running\e[0m after start";
        say "";

        # Check stderr for common causes
        my $target_flag = $target ne 'dev' ? " $target" : "";
        my $logs = $transport->run("tail -20 /tmp/$name.stderr.log 2>/dev/null");
        my $stderr = $logs->{output} // '';

        if ($stderr =~ /Can't locate (\S+\.pm).*you may need to install the (\S+) module/s) {
            say "  \e[33mMissing module: $2\e[0m";
            say "  Perl deps are not fully installed.";
            say "";
            say "  Fix: install deps then restart:";
            say "    321 install $name$target_flag";
        } elsif ($stderr =~ /Can't locate (\S+\.pm)/s) {
            (my $module = $1) =~ s/\//::/g; $module =~ s/\.pm$//;
            say "  \e[33mMissing module: $module\e[0m";
            say "  Perl deps are not fully installed.";
            say "";
            say "  Fix: install deps then restart:";
            say "    321 install $name$target_flag";
        } else {
            say "  Next: check logs:";
            say "    321 logs $name$target_flag --stderr";
        }
    }
}

1;

=head1 SYNOPSIS

  Usage: APPLICATION start <service>

=cut
