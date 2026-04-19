package Deploy::Command::install;

use Mojo::Base 'Deploy::Command', -signatures;
use Deploy::Local;

has description => 'First-time install: clone, perlbrew, deps, ubic, nginx, ssl';
has usage => sub ($self) { $self->extract_usage };

sub run ($self, @args) {
    my ($svc_input, $target) = $self->parse_target(@args);
    die $self->usage unless $svc_input;
    my $name = $self->resolve_service($svc_input);
    my $transport = $self->transport_for($name, $target);

    my $cfg = $self->config;
    $cfg->target($target);
    my $svc = $cfg->service($name);

    my $repo     = $svc->{repo};
    my $branch   = $svc->{branch} // 'master';
    my $perlbrew = $svc->{perlbrew};
    my $host     = $svc->{host} // 'localhost';
    my $port     = $svc->{port};

    say "3... 2... 1... installing $name ($target)";
    say "";

    # Step 1: Check/install perlbrew
    if ($perlbrew) {
        say "  Checking perlbrew...";
        my $r = $transport->run('which perlbrew 2>/dev/null || echo MISSING');
        if ($r->{output} =~ /MISSING/) {
            say "  Installing perlbrew...";
            $r = $transport->run('curl -L https://install.perlbrew.pl | bash && echo "source ~/perl5/perlbrew/etc/bashrc" >> ~/.bashrc', timeout => 120);
            die "  perlbrew install failed: $r->{output}\n" unless $r->{ok};
            say "  [OK] perlbrew installed";
        } else {
            say "  [OK] perlbrew already installed";
        }

        # Step 2: Check/install perl version
        say "  Checking $perlbrew...";
        $r = $transport->run("perlbrew list | grep -q '$perlbrew'");
        unless ($r->{ok}) {
            say "  Installing $perlbrew (this takes 10-20 minutes)...";
            $r = $transport->run("perlbrew install $perlbrew --notest -j4", timeout => 1800);
            die "  $perlbrew install failed: $r->{output}\n" unless $r->{ok};
            say "  [OK] $perlbrew installed";
        } else {
            say "  [OK] $perlbrew available";
        }

        # Step 3: Install cpanm
        say "  Checking cpanm...";
        $r = $transport->run('perlbrew install-cpanm 2>&1');
        say "  [OK] cpanm ready";
    }

    # Step 4: Clone repo
    say "  Checking repo $repo...";
    my $r = $transport->run("test -d $repo && echo EXISTS");
    if ($r->{output} =~ /EXISTS/) {
        say "  [OK] Repo already exists";
    } else {
        say "  Cloning repo...";
        my $git_url = $self->_guess_git_url($repo);
        die "  No repo at $repo and cannot guess git URL\n" unless $git_url;
        $r = $transport->run("git clone -b $branch $git_url $repo", timeout => 120);
        die "  Clone failed: $r->{output}\n" unless $r->{ok};
        say "  [OK] Cloned $git_url";
    }

    # Check manifest locally — 321.yml lives in the service repo on this machine
    unless (-f "$repo/321.yml") {
        say "  No 321.yml found in $repo - creating boilerplate...";
        require Path::Tiny;
        $self->_scaffold_manifest($repo, $name, Deploy::Local->new);
        say "  [OK] Created $repo/321.yml - edit it to match your app, then re-run install";
        say "";
        say "  vim $repo/321.yml";
        return;
    }
    say "  [OK] Manifest found";

    # Step 5: Install deps
    say "  Installing dependencies...";
    $r = $transport->run_in_dir($repo, 'cpanm -L local --notest --installdeps .', timeout => 600);
    say $r->{ok} ? "  [OK] Dependencies installed" : "  [WARN] cpanm had errors (continuing)";

    # Step 6: Bootstrap ubic (first time)
    $r = $transport->run('test -f ~/.ubic.cfg && echo EXISTS');
    unless ($r->{output} =~ /EXISTS/) {
        say "  Bootstrapping ubic...";
        $transport->run('cpanm --notest Ubic Ubic::Service::SimpleDaemon', timeout => 300);
        $r = $transport->run('ubic-admin setup --batch-mode --local');
        die "  ubic-admin setup failed: $r->{output}\n" unless $r->{ok};
        say "  [OK] Ubic bootstrapped";
    } else {
        say "  [OK] Ubic already set up";
    }

    # Step 7: Generate ubic service file
    say "  Generating ubic service...";
    my $gen = $self->ubic->generate($name);
    if ($svc->{ssh}) {
        $transport->run("mkdir -p \$(dirname $gen->{path})");
        $transport->upload($gen->{path}, $gen->{path});
    }
    $self->ubic->install_symlinks;
    say "  [OK] Ubic service ready";

    # Step 8: Start service
    say "  Starting service...";
    $r = $transport->run("ubic start $name 2>&1");
    say "  [OK] Service started";

    # Step 9: Nginx
    if ($host ne 'localhost' && $port) {
        say "  Setting up nginx for $host -> :$port...";
        $self->nginx->transport($transport);
        my $nginx_result = $self->nginx->setup($name);
        for my $step (@{ $nginx_result->{steps} // [] }) {
            my $s = ref $step->{success} ? ${$step->{success}} : $step->{success};
            printf "  [%s] %s\n", ($s ? 'OK' : 'WARN'), $step->{step};
        }

        # Step 10: SSL cert
        my $provider = $self->nginx->cert_provider->pick($target);
        say "  Requesting SSL certificate via $provider...";
        my $cert = $self->nginx->acquire_cert($name);
        if ($cert->{status} eq 'ok') {
            say "  [OK] SSL cert ready ($provider)";
            $self->nginx->generate($name);
            $self->nginx->reload;
        } else {
            warn "  [WARN] $provider failed - run manually later\n";
        }
    }

    say "";
    say "  $name installed on $target.";
}

sub _scaffold_manifest ($self, $repo, $name, $transport) {
    my $manifest = <<"YAML";
# 321.yml - service manifest for $name
#
# This file tells 321 how to run your app.
# Edit the values below, then re-run: 321 install $name

# Service identity
name: $name

# Entry point - the script 321 starts via hypnotoad/morbo
entry: bin/app.pl

# Default process runner: hypnotoad (production) or morbo (dev, auto-reload)
runner: hypnotoad

# Perl version managed by perlbrew (omit if using system perl)
# perl: perl-5.42.0

# Health check path - 321 hits this after deploy to verify the app is up
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
#   SECRET_KEY: "Session signing key"

# Variables with sensible defaults (optional to set)
# env_optional:
#   LOG_LEVEL:
#     default: info
#     desc: "debug | info | warn | error"
YAML

    require Path::Tiny;
    my $tmp = Path::Tiny::path("/tmp/321-manifest-$$.yml");
    $tmp->spew_utf8($manifest);
    $transport->upload("$tmp", "$repo/321.yml");
    $tmp->remove;
}

sub _guess_git_url ($self, $repo) {
    my $parent = Mojo::File->new($repo)->dirname;
    return undef unless -d $parent;
    for my $sibling ($parent->list->each) {
        next unless -d "$sibling/.git";
        my $url = `cd $sibling && git remote get-url origin 2>/dev/null`;
        chomp $url;
        next unless $url;
        my $sibling_name = $sibling->basename;
        my $target_name  = Mojo::File->new($repo)->basename;
        (my $guessed = $url) =~ s/\Q$sibling_name\E/$target_name/;
        return $guessed if $guessed ne $url;
    }
    return undef;
}

1;

=head1 SYNOPSIS

  Usage: APPLICATION install <service> [target]

  First-time setup: clone, perlbrew, deps, ubic, nginx, SSL.

  321 install love.web         # install locally
  321 install love.web live    # install on remote server via SSH

=cut
