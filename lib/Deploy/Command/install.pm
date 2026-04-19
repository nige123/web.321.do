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
    my $is_remote = $svc->{ssh} ? 1 : 0;
    my $ssh_target = $svc->{ssh} // 'localhost';

    say "3... 2... 1... installing $name ($target)";
    say "";

    # --- Perlbrew ---
    if ($perlbrew) {
        say "  Checking perlbrew...";
        my $r = $transport->run('which perlbrew 2>/dev/null || echo MISSING');
        if ($r->{output} =~ /MISSING/) {
            say "  Installing perlbrew...";
            $r = $transport->run('curl -L https://install.perlbrew.pl | bash && echo "source ~/perl5/perlbrew/etc/bashrc" >> ~/.bashrc', timeout => 120);
            unless ($r->{ok}) {
                say "  [FAIL] perlbrew install failed";
                say "";
                say "  Next: SSH in and install perlbrew manually:";
                say "    ssh $ssh_target";
                say "    curl -L https://install.perlbrew.pl | bash";
                say "  Then re-run: 321 install $name $target";
                return;
            }
        }
        # Verify perlbrew works
        $r = $transport->run('perlbrew version');
        unless ($r->{ok}) {
            say "  [FAIL] perlbrew not working";
            say "";
            say "  Next: check perlbrew installation on $ssh_target";
            return;
        }
        say "  [OK] perlbrew";

        # --- Perl version ---
        say "  Checking $perlbrew...";
        $r = $transport->run("perlbrew list | grep -q '$perlbrew'");
        unless ($r->{ok}) {
            say "  Installing $perlbrew (this takes 10-20 minutes)...";
            $r = $transport->run("perlbrew install $perlbrew --notest -j4", timeout => 1800);
        }
        # Verify perl version available
        $r = $transport->run("perlbrew list | grep -q '$perlbrew'");
        unless ($r->{ok}) {
            say "  [FAIL] $perlbrew not available after install";
            say "";
            say "  Next: SSH in and install manually:";
            say "    ssh $ssh_target";
            say "    perlbrew install $perlbrew --notest -j4";
            say "  Then re-run: 321 install $name $target";
            return;
        }
        say "  [OK] $perlbrew";

        # --- cpanm ---
        say "  Checking cpanm...";
        $transport->run('perlbrew install-cpanm 2>&1');
        $r = $transport->run('which cpanm 2>/dev/null');
        unless ($r->{ok}) {
            say "  [FAIL] cpanm not available";
            say "";
            say "  Next: ssh $ssh_target && perlbrew install-cpanm";
            say "  Then re-run: 321 install $name $target";
            return;
        }
        say "  [OK] cpanm";
    }

    # --- Clone repo ---
    say "  Checking repo $repo...";
    my $r = $transport->run("test -d $repo/.git && echo EXISTS");
    unless ($r->{output} =~ /EXISTS/) {
        say "  Cloning repo...";
        my $manifest = $self->config->service_raw($name);
        my $git_url = $manifest->{git_url} // $self->_guess_git_url($repo);
        unless ($git_url) {
            say "  [FAIL] No git URL configured";
            say "";
            say "  Next: add to $repo/321.yml:";
            say "    repo: git\@github.com:user/repo.git";
            say "  Then re-run: 321 install $name $target";
            return;
        }
        $transport->run("test -d $repo && rm -rf $repo");
        $r = $transport->run("git clone -b $branch $git_url $repo", timeout => 120);
        unless ($r->{ok}) {
            say "  [FAIL] Clone failed";
            say "  $r->{output}" if $r->{output};
            say "";
            say "  Next: check git SSH access on $ssh_target:";
            say "    ssh $ssh_target";
            say "    ssh -T git\@github.com";
            say "  Then re-run: 321 install $name $target";
            return;
        }
    }
    # Verify repo exists
    $r = $transport->run("test -d $repo/.git && echo OK");
    unless ($r->{output} =~ /OK/) {
        say "  [FAIL] Repo not found at $repo";
        return;
    }
    say "  [OK] repo";

    # --- Manifest ---
    unless (-f "$repo/321.yml") {
        say "  No 321.yml found - creating boilerplate...";
        $self->_scaffold_manifest($repo, $name, Deploy::Local->new);
        say "  [STOP] Created $repo/321.yml";
        say "";
        say "  Next: edit the manifest, then re-run:";
        say "    vim $repo/321.yml";
        say "    321 install $name $target";
        return;
    }
    say "  [OK] manifest";

    # --- Dependencies ---
    say "  Installing dependencies...";
    $r = $transport->run_in_dir($repo, 'cpanm -L local --notest --installdeps .', timeout => 600);
    # Verify local/ was created
    my $check = $transport->run("test -d $repo/local && echo OK");
    if ($check->{output} =~ /OK/) {
        say "  [OK] deps";
    } else {
        say "  [WARN] cpanm may have had errors (continuing)";
    }

    # --- Ubic ---
    $r = $transport->run('test -f ~/.ubic.cfg && echo EXISTS');
    unless ($r->{output} =~ /EXISTS/) {
        say "  Bootstrapping ubic...";
        $transport->run('cpanm --notest Ubic Ubic::Service::SimpleDaemon', timeout => 300);
        $r = $transport->run('ubic-admin setup --batch-mode --local');
    }
    # Verify ubic works
    $r = $transport->run('ubic status 2>&1 | head -1');
    unless ($r->{ok}) {
        say "  [FAIL] ubic not working";
        say "";
        say "  Next: SSH in and bootstrap ubic:";
        say "    ssh $ssh_target";
        say "    cpanm --notest Ubic Ubic::Service::SimpleDaemon";
        say "    ubic-admin setup --batch-mode --local";
        say "  Then re-run: 321 install $name $target";
        return;
    }
    say "  [OK] ubic";

    # --- Generate ubic service file ---
    say "  Generating ubic service...";
    my $gen = $self->ubic->generate($name);
    if ($is_remote) {
        $transport->run("mkdir -p \$(dirname $gen->{path})");
        $transport->upload($gen->{path}, $gen->{path});
        # Install symlink on remote
        my ($group, $svc_name) = split /\./, $name, 2;
        $transport->run("mkdir -p ~/ubic/service/$group");
        $transport->run("ln -sf $gen->{path} ~/ubic/service/$group/$svc_name");
    } else {
        $self->ubic->install_symlinks;
    }
    say "  [OK] ubic service";

    # --- Start service ---
    say "  Starting $name...";
    $r = $transport->run("ubic start $name 2>&1");
    # Verify it's running
    sleep 2;
    $r = $transport->run("ubic status $name 2>&1");
    if ($r->{output} =~ /running/) {
        say "  [OK] running";
    } else {
        say "  [FAIL] service not running after start";
        say "  $r->{output}" if $r->{output};
        say "";
        say "  Next: check logs:";
        say "    321 logs $name $target --stderr";
        say "  Then re-run: 321 install $name $target";
        return;
    }

    # --- Nginx ---
    if ($host ne 'localhost' && $port) {
        say "  Setting up nginx for $host -> :$port...";
        $self->nginx->transport($transport);
        my $nginx_result = $self->nginx->setup($name);
        # Verify nginx is OK
        my $nginx_ok = 1;
        for my $step (@{ $nginx_result->{steps} // [] }) {
            my $s = ref $step->{success} ? ${$step->{success}} : $step->{success};
            unless ($s) {
                say "  [FAIL] nginx $step->{step}";
                $nginx_ok = 0;
                last;
            }
        }
        if ($nginx_ok) {
            say "  [OK] nginx";
        } else {
            say "";
            say "  Next: check nginx config:";
            say "    ssh $ssh_target";
            say "    sudo nginx -t";
            say "  Then re-run: 321 install $name $target";
            return;
        }

        # --- SSL ---
        my $provider = $self->nginx->cert_provider->pick($target);
        say "  Requesting SSL certificate via $provider...";
        my $cert = $self->nginx->acquire_cert($name);
        if ($cert->{status} eq 'ok') {
            say "  [OK] ssl ($provider)";
            $self->nginx->generate($name);
            $self->nginx->reload;
        } else {
            say "  [SKIP] $provider failed - DNS may not be pointed yet";
            say "";
            say "  Next: point DNS for $host to the server, then:";
            say "    321 install $name $target";
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

# Git clone URL (used by 321 install to clone on remote servers)
# repo: git\@github.com:user/$name.git

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
