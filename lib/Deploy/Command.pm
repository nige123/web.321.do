package Deploy::Command;

use Mojo::Base 'Mojolicious::Command', -signatures;

sub config  ($self) { $self->app->config_obj }
sub ubic    ($self) { $self->app->ubic_mgr_obj }
sub nginx   ($self) { $self->app->nginx_mgr_obj }
sub svc_mgr ($self) { $self->app->svc_mgr_obj }

sub resolve_service ($self, $input) {
    my @names = @{ $self->config->service_names };

    return $input if grep { $_ eq $input } @names;

    # Prefix match
    my @m = grep { index(lc $_, lc $input) == 0 } @names;
    return $m[0] if @m == 1;

    # Substring match
    @m = grep { index(lc $_, lc $input) >= 0 } @names;
    return $m[0] if @m == 1;

    die @m > 1
        ? "Ambiguous: '$input' matches: " . join(', ', @m) . "\n"
        : "Unknown service: $input\nServices: " . join(', ', @names) . "\n";
}

sub run_cmd ($self, $cmd) {
    system($cmd) == 0 or die "Command failed: $cmd\n";
}

sub run_cpanm ($self, $repo, $perlbrew) {
    my $cmd = 'cpanm --notest --installdeps .';
    if ($perlbrew) {
        $cmd = "bash -lc 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use $perlbrew && $cmd'";
    }
    return system("cd $repo && $cmd 2>&1") == 0;
}

1;
