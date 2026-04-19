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

    if (@m > 1) {
        die "Ambiguous: '$input' matches: " . join(', ', @m) . "\n";
    }

    # Not found — scaffold 321.yml if we're in a repo dir without one
    if (-d '.git' && ! -f '321.yml') {
        require Cwd;
        my $cwd = Cwd::getcwd();
        say "Unknown service: $input";
        say "Known services: " . join(', ', @names) if @names;
        say "";
        say "Creating 321.yml in $cwd ...";
        $self->_write_boilerplate($input);
        say "";
        say "Next: edit 321.yml then re-run your command:";
        say "  nano 321.yml";
        say "  321 install $input";
        exit 0;
    }

    my $msg = "Unknown service: $input\n";
    $msg .= "Known services: " . join(', ', @names) . "\n" if @names;
    $msg .= "\nTo register a new service, create a 321.yml in its repo:\n";
    $msg .= "  cd /home/s3/<repo> && 321 install $input\n";
    die $msg;
}

sub parse_target ($self, @args) {
    if (!@args) {
        # No args — try to infer service from cwd
        my $svc = $self->_infer_service;
        return ($svc, 'dev') if $svc;
        return (undef, 'dev');
    }
    if (@args == 1) {
        # Is it a known target name? If so, infer service from cwd
        if ($self->_is_target_name($args[0])) {
            my $svc = $self->_infer_service;
            return ($svc, $args[0]) if $svc;
            return (undef, $args[0]);
        }
        return ($args[0], 'dev');
    }
    my ($svc_input, $target_input) = @args;
    return ($svc_input, $target_input);
}

sub _infer_service ($self) {
    my $manifest_file = Mojo::File->new('321.yml');
    return undef unless -f $manifest_file;
    require YAML::XS;
    my $raw = YAML::XS::LoadFile($manifest_file->to_string);
    return $raw->{name} if ref $raw eq 'HASH' && $raw->{name};
    return undef;
}

sub _is_target_name ($self, $name) {
    for my $svc_name (@{ $self->config->service_names }) {
        my $raw = $self->config->service_raw($svc_name);
        return 1 if exists $raw->{targets}{$name};
    }
    return 0;
}

sub transport_for ($self, $name, $target) {
    require Deploy::Transport;
    my $cfg = $self->config;
    my $old_target = $cfg->target;
    $cfg->target($target);
    my $svc = $cfg->service($name);
    $cfg->target($old_target);
    return undef unless $svc;
    return Deploy::Transport->for_target($svc, perlbrew => $svc->{perlbrew});
}

sub _write_boilerplate ($self, $name) {
    require Path::Tiny;
    Path::Tiny::path('321.yml')->spew_utf8(<<"YAML");
# 321.yml - service manifest for $name
#
# This file tells 321 how to run your app.
# Edit the values below, then run: 321 install $name

# Service identity
name: $name

# Git clone URL (used by 321 install to clone on remote servers)
# repo: git\@github.com:user/repo.git

# Entry point - the script 321 starts via hypnotoad/morbo
entry: bin/app.pl

# Default process runner: hypnotoad (production) or morbo (dev, auto-reload)
runner: hypnotoad

# Perl version managed by perlbrew (omit if using system perl)
perl: perl-5.42.0

# Health check path (GET, must return 200)
# health: /health

# Git branch to deploy from
# branch: main

# === Targets ===
# Each target defines where and how the service runs.
# 'dev' runs locally, 'live' runs on a remote server via SSH.

dev:
    host: $name.dev
    port: 8080
    runner: morbo

# live:
#     ssh: ubuntu\@your-ec2-host.compute.amazonaws.com
#     ssh_key: ~/.ssh/your-key.pem
#     host: your-domain.com
#     port: 8080
#     runner: hypnotoad

# === Environment Variables ===

# Variables the app requires to start (deploy blocked if missing)
# env_required:
#   DATABASE_URL: "Postgres connection string"

# Variables with sensible defaults (optional to set)
# env_optional:
#   LOG_LEVEL:
#     default: info
#     desc: "debug | info | warn | error"
YAML
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
