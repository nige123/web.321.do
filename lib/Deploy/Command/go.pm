package Deploy::Command::go;

use Mojo::Base 'Deploy::Command', -signatures;

has description => 'Deploy a service: git pull, cpanm, ubic restart';
has usage => sub ($self) { $self->extract_usage };

sub run ($self, @args) {
    die $self->usage unless @args;
    my $name = $self->resolve_service($args[0]);

    say "3... 2... 1... go! Deploying $name";
    my $svc      = $self->config->service($name);
    my $skip_git = ($svc->{mode} // 'production') eq 'development';

    my $result = $self->svc_mgr->deploy($name, skip_git => $skip_git);

    for my $step (@{ $result->{data}{steps} // [] }) {
        my $ok = ref $step->{success} ? ${$step->{success}} : $step->{success};
        printf "  [%s] %s\n", ($ok ? 'OK' : 'FAIL'), $step->{step};
    }
    say "  $result->{message}";
    exit 1 if $result->{status} ne 'success';
}

1;

=head1 SYNOPSIS

  Usage: APPLICATION go <service>

  321 go zorda.web   # deploy latest code

=cut
