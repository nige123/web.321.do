package Deploy::Command::install;

use Mojo::Base 'Deploy::Command', -signatures;

has description => 'First-time install: clone, deps, ubic, nginx, certbot';
has usage => sub ($self) { $self->extract_usage };

sub run ($self, @args) {
    die $self->usage unless @args;
    my $name = $self->resolve_service($args[0]);

    my $svc      = $self->config->service($name);
    my $repo     = $svc->{repo};
    my $branch   = $svc->{branch} // 'master';
    my $perlbrew = $svc->{perlbrew};
    my $host     = $svc->{host} // 'localhost';
    my $port     = $svc->{port};

    say "3... 2... 1... installing $name";
    say "";

    # Step 1: Clone repo
    if (-d $repo) {
        say "  [OK] Repo already exists: $repo";
    } else {
        say "  Cloning repo to $repo...";
        my $git_url = $self->_guess_git_url($repo);
        if ($git_url) {
            $self->run_cmd("git clone -b $branch $git_url $repo");
            say "  [OK] Cloned $git_url";
        } else {
            die "  Repo $repo does not exist and no git URL found.\n";
        }
    }

    # Step 2: Install deps
    say "  Installing dependencies...";
    my $ok = $self->run_cpanm($repo, $perlbrew);
    say $ok ? "  [OK] Dependencies installed" : "  [WARN] cpanm had errors (continuing)";

    # Step 3: Ubic service
    say "  Setting up ubic service...";
    my $gen = $self->ubic->generate($name);
    say "  [OK] Generated: $gen->{path}";
    $self->ubic->install_symlinks;
    say "  [OK] Symlinks installed";

    # Step 4: Start service
    say "  Starting service...";
    system("ubic start $name 2>&1");
    say "  [OK] Service started";

    # Step 5: Nginx + SSL
    if ($host ne 'localhost' && $port) {
        say "  Setting up nginx for $host -> :$port...";
        my $result = $self->nginx->setup($name);
        for my $step (@{ $result->{steps} // [] }) {
            my $s = ref $step->{success} ? ${$step->{success}} : $step->{success};
            printf "  [%s] %s\n", ($s ? 'OK' : 'WARN'), $step->{step};
        }

        say "  Requesting SSL certificate for $host...";
        my $cert = $self->nginx->certbot($name);
        if ($cert->{status} eq 'ok') {
            say "  [OK] SSL cert ready";
            $self->nginx->generate($name);
            $self->nginx->reload;
        } else {
            warn "  [WARN] Certbot failed — run: sudo certbot certonly --standalone -d $host\n";
        }
    } else {
        say "  [SKIP] No host/port, skipping nginx";
    }

    say "";
    say "  $name installed.";
}

sub _guess_git_url ($self, $repo) {
    my $parent = Mojo::File->new($repo)->dirname;
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

  Usage: APPLICATION install <service>

  Options:
    -h, --help   Show this message

  321 install zorda.web   # clone, deps, ubic, nginx, certbot

=cut
