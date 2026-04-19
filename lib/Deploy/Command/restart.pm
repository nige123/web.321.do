package Deploy::Command::restart;

use Mojo::Base 'Deploy::Command', -signatures;

has description => 'Restart a service';
has usage => sub ($self) { $self->extract_usage };

sub run ($self, @args) {
    my ($svc_input, $target) = $self->parse_target(@args);
    die $self->usage unless $svc_input;
    my $name = $self->resolve_service($svc_input);
    my $transport = $self->transport_for($name, $target);

    my $svc_mgr = $self->svc_mgr;
    $svc_mgr->transport($transport);
    my $r = $svc_mgr->restart($name);
    for my $step (@{ $r->{data}{steps} // [] }) {
        my $ok = $svc_mgr->_ok($step);
        printf "  [%s] %s\n", ($ok ? 'OK' : 'FAIL'), $step->{step};
    }
    if ($r->{status} eq 'success') {
        my $svc  = $self->config->service($name);
        my $port = $svc->{port} // '?';
        my $host = $svc->{host} // 'localhost';
        my $url  = $host ne 'localhost' ? "https://$host/" : "http://localhost:$port/";
        say "  $r->{message}  port:$port  $url";
    } else {
        say "  $r->{message}" if $r->{message};
    }
}

1;

=head1 SYNOPSIS

  Usage: APPLICATION restart <service>

=cut
