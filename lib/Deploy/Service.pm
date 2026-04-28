package Deploy::Service;

use Mojo::Base -base, -signatures;
use Mojo::IOLoop;
use Path::Tiny qw(path);
use POSIX qw(strftime);
use Deploy::Local;

has 'config';     # Deploy::Config instance
has 'log';        # Mojo::Log instance
has 'ubic_mgr';   # Deploy::Ubic instance
has 'transport' => sub { Deploy::Local->new };

sub status ($self, $name) {
    my $svc = $self->config->service($name);
    return undef unless $svc;

    my $pid = $self->_get_pid($name, $svc);
    my $git_sha = $self->_git_sha($svc->{repo});
    # Only check port if ubic says it's running — avoids 2s curl timeout per stopped service
    my $port_ok = $pid ? $self->_check_port($svc->{port}) : 0;

    return {
        name    => $name,
        pid     => $pid,
        port    => $svc->{port},
        running => $port_ok ? \1 : \0,
        git_sha => $git_sha,
        repo    => $svc->{repo},
        branch  => $svc->{branch},
        mode    => $svc->{mode} // 'production',
        runner  => $svc->{runner} // 'hypnotoad',
        host    => $svc->{host} // 'localhost',
        ($svc->{favicon} ? (favicon => $svc->{favicon}) : ()),
        ($svc->{docs}    ? (docs    => $svc->{docs})    : ()),
        ($svc->{admin}   ? (admin   => $svc->{admin})   : ()),
    };
}

sub all_status ($self) {
    # Batch ubic status in one call — avoids N subprocess calls
    my %ubic_pids;
    my $r = $self->transport->run("ubic status");
    if ($r->{ok}) {
        for my $line (split /\n/, $r->{output} // '') {
            if ($line =~ /^\s+(\S+)\t(?:running \(pid (\d+)\)|(.+))/) {
                $ubic_pids{$1} = $2;  # undef if not running
            }
        }
    }

    my @results;
    for my $name (@{ $self->config->service_names }) {
        my $svc = $self->config->service($name);
        next unless $svc;

        my $pid = $ubic_pids{$name};
        my $git_sha = $self->_git_sha($svc->{repo});
        my $port_ok = $pid ? $self->_check_port($svc->{port}) : 0;

        push @results, {
            name    => $name,
            pid     => $pid,
            port    => $svc->{port},
            running => $port_ok ? \1 : \0,
            git_sha => $git_sha,
            repo    => $svc->{repo},
            branch  => $svc->{branch},
            mode    => $svc->{mode} // 'production',
            runner  => $svc->{runner} // 'hypnotoad',
            host    => $svc->{host} // 'localhost',
            ($svc->{is_worker} ? (is_worker => 1) : ()),
            ($svc->{favicon}   ? (favicon   => $svc->{favicon}) : ()),
            ($svc->{docs}      ? (docs      => $svc->{docs})    : ()),
            ($svc->{admin}     ? (admin     => $svc->{admin})   : ()),
        };
    }
    return \@results;
}

sub deploy ($self, $name, %opts) {
    my $svc = $self->config->service($name);
    return { status => 'error', message => "Unknown service: $name" } unless $svc;

    # Check repo exists on target
    my $r = $self->transport->run("test -d $svc->{repo}/.git");
    unless ($r->{ok}) {
        return {
            status  => 'error',
            message => "Repo not found at $svc->{repo} - run '321 install $name' first",
        };
    }

    my $skip_git = $opts{skip_git} // 0;
    my @steps;

    my $s = $self->_step_apt_deps($svc);
    push @steps, $s;
    my $apt_ok = $self->_ok($s);
    return $self->_deploy_result($name, 'error', 'System packages missing', \@steps)
        unless $apt_ok;

    unless ($skip_git) {
        $s = $self->_step_git_pull($svc);
        push @steps, $s;
        return $self->_deploy_result($name, 'error', 'Git pull failed', \@steps)
            unless $self->_ok($s);
    }

    $s = $self->_step_cpanm($svc);
    push @steps, $s;
    $self->log->warn("cpanm failed for $name: $s->{output}") unless $self->_ok($s);

    if (-x "$svc->{repo}/bin/migrate") {
        $s = $self->_step_migrate($svc);
        push @steps, $s;
        return $self->_deploy_result($name, 'error', 'Migration failed', \@steps)
            unless $self->_ok($s);
    }

    if ($self->ubic_mgr) {
        my $gen = $self->ubic_mgr->generate($name);
        push @steps, { step => 'generate_ubic', success => \1, output => "Generated: $gen->{path}" };
    }

    $s = $self->_step_ubic_restart($name);
    push @steps, $s;
    return $self->_deploy_result($name, 'error', 'Ubic restart failed', \@steps)
        unless $self->_ok($s);

    sleep 2;
    $s = $self->_step_port_check($svc);
    push @steps, $s;

    $self->_log_deploy($name, \@steps);

    my $tag = $skip_git ? ' (dev)' : '';
    my $port_ok = $self->_ok($s);
    my $final_status = $port_ok ? 'success' : 'error';
    my $final_msg = $port_ok
        ? "Deployed $name$tag successfully"
        : "Deployed $name$tag but port check failed";
    return $self->_deploy_result($name, $final_status, $final_msg, \@steps);
}

sub _step_apt_deps ($self, $svc) {
    my ($ok, $out) = $self->_check_apt_deps($svc);
    return { step => 'apt_deps', success => $ok ? \1 : \0, output => $out };
}

sub _step_git_pull ($self, $svc) {
    my $branch = $svc->{branch} // 'master';
    my $r = $self->_run_in_dir($svc->{repo},
        "git fetch origin && git reset --hard origin/$branch");
    return { step => 'git_pull', success => $r->{ok} ? \1 : \0, output => $r->{output} };
}

sub _step_cpanm ($self, $svc) {
    my $r = $self->_run_in_dir($svc->{repo}, $self->_cpanm_cmd($svc->{perlbrew}));
    return { step => 'cpanm', success => $r->{ok} ? \1 : \0, output => $r->{output} };
}

sub _step_ubic_restart ($self, $name) {
    my $r = $self->_run_cmd("ubic restart $name");
    return { step => 'ubic_restart', success => $r->{ok} ? \1 : \0, output => $r->{output} };
}

sub _step_migrate ($self, $svc) {
    my $repo = $svc->{repo};
    my $env_prefix = "PERL5LIB=$repo/local/lib/perl5 PATH=$repo/local/bin:\$PATH";
    my $r = $self->_run_in_dir($repo, "$env_prefix ./bin/migrate");
    return { step => 'migrate', success => $r->{ok} ? \1 : \0, output => $r->{output} };
}

# Every _step_* returns { success => \1 | \0 }. Callers deref via this helper.
sub _ok ($self, $step) {
    return ref $step->{success} ? ${ $step->{success} } : $step->{success};
}

sub _step_port_check ($self, $svc) {
    my $ok = $self->_check_port($svc->{port});
    return {
        step    => 'port_check',
        success => $ok ? \1 : \0,
        output  => $ok ? "Port $svc->{port} responding" : "Port $svc->{port} not responding",
    };
}

sub deploy_dev ($self, $name) {
    return $self->deploy($name, skip_git => 1);
}

sub restart ($self, $name) {
    my $svc = $self->config->service($name);
    return { status => 'error', message => "Unknown service: $name" } unless $svc;

    my @steps;

    my $s = $self->_step_ubic_restart($name);
    push @steps, $s;
    return $self->_deploy_result($name, 'error', 'Ubic restart failed', \@steps)
        unless $self->_ok($s);

    sleep 2;
    $s = $self->_step_port_check($svc);
    push @steps, $s;

    my $port_ok = $self->_ok($s);
    return $self->_deploy_result(
        $name,
        $port_ok ? 'success' : 'error',
        $port_ok ? "Restarted $name" : 'Port check failed after restart',
        \@steps,
    );
}

sub migrate ($self, $name) {
    my $svc = $self->config->service($name);
    return { status => 'error', message => "Unknown service: $name" } unless $svc;

    unless (-x "$svc->{repo}/bin/migrate") {
        return $self->_deploy_result($name, 'success', "no bin/migrate in $svc->{repo}", []);
    }

    my $s = $self->_step_migrate($svc);
    my $ok = $self->_ok($s);
    return $self->_deploy_result(
        $name,
        $ok ? 'success' : 'error',
        $ok ? "Migrated $name" : 'Migration failed',
        [$s],
    );
}

sub update ($self, $name) {
    my $svc = $self->config->service($name);
    return { status => 'error', message => "Unknown service: $name" } unless $svc;

    my @steps;

    my $s = $self->_step_apt_deps($svc);
    push @steps, $s;
    return $self->_deploy_result($name, 'error', 'System packages missing', \@steps)
        unless $self->_ok($s);

    $s = $self->_step_git_pull($svc);
    push @steps, $s;
    return $self->_deploy_result($name, 'error', 'Git pull failed', \@steps)
        unless $self->_ok($s);

    $s = $self->_step_cpanm($svc);
    push @steps, $s;
    $self->log->warn("cpanm failed for $name: $s->{output}") unless $self->_ok($s);

    if (-x "$svc->{repo}/bin/migrate") {
        $s = $self->_step_migrate($svc);
        push @steps, $s;
        return $self->_deploy_result($name, 'error', 'Migration failed', \@steps)
            unless $self->_ok($s);
    }

    return $self->_deploy_result($name, 'success', "Updated $name (no restart)", \@steps);
}

sub _check_apt_deps ($self, $svc) {
    my $deps = $svc->{apt_deps} // [];
    return (1, 'no apt_deps declared') unless @$deps;

    my @missing;
    for my $pkg (@$deps) {
        my $r = $self->transport->run("dpkg -s \Q$pkg\E >/dev/null 2>&1");
        push @missing, $pkg unless $r->{ok};
    }

    return (1, 'all installed: ' . join(' ', @$deps)) unless @missing;

    # Auto-install missing packages
    my $cmd = 'sudo apt-get install -y ' . join(' ', @missing);
    $self->log->info("Installing missing apt deps: " . join(', ', @missing));
    my $r = $self->transport->run($cmd, timeout => 300);
    return $r->{ok}
        ? (1, 'installed: ' . join(' ', @missing))
        : (0, "Failed to install: " . join(', ', @missing) . "\n$r->{output}");
}

sub _cpanm_cmd ($self, $perlbrew) {
    # Install into ./local/ so each repo owns its dep tree. Runtime env
    # (PERL5LIB/PATH) is wired up by Deploy::Ubic when generating the
    # service wrapper.
    my $cmd = 'cpanm -L local --notest --installdeps .';
    return $cmd unless $perlbrew;
    return "bash -lc 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use $perlbrew && $cmd'";
}

sub _deploy_result ($self, $name, $status, $message, $steps) {
    return {
        status  => $status,
        message => $message,
        data    => {
            service => $name,
            steps   => $steps,
            timestamp => strftime('%Y-%m-%dT%H:%M:%SZ', gmtime),
        },
    };
}

sub _run_in_dir ($self, $dir, $cmd, %opts) {
    my $timeout = $opts{timeout} // 600;
    $self->log->info("Running: cd $dir && $cmd");
    return $self->transport->run_in_dir($dir, $cmd, timeout => $timeout);
}

sub _run_cmd ($self, $cmd) {
    $self->log->info("Running: $cmd");
    return $self->transport->run($cmd, timeout => 120);
}

sub _get_pid ($self, $name, $svc) {
    my $r = $self->transport->run("ubic status $name");
    if ($r->{ok} && $r->{output} =~ /running \(pid (\d+)\)/) {
        return $1;
    }

    # Fallback: check hypnotoad.pid (may be in bin/ or repo root)
    for my $loc ('bin/hypnotoad.pid', 'hypnotoad.pid') {
        my $pidfile = path($svc->{repo}, $loc);
        next unless $pidfile->exists;
        my $pid = $pidfile->slurp;
        $pid =~ s/\s+//g;
        next unless $pid =~ /^\d+$/;
        return $pid if kill(0, $pid);
    }
    return undef;
}

sub _git_sha ($self, $repo) {
    my $r = $self->transport->run_in_dir($repo, 'git rev-parse --short HEAD');
    return undef unless $r->{ok};
    chomp(my $sha = $r->{output});
    return $sha || undef;
}

sub _check_port ($self, $port) {
    return 0 unless $port;
    my $r = $self->transport->run("curl -sf -o /dev/null --connect-timeout 1 http://127.0.0.1:$port/", timeout => 3);
    return $r->{ok} ? 1 : 0;
}

sub _log_deploy ($self, $name, $steps) {
    my $dir = path('/tmp/321.do/deploys');
    $dir->mkpath;
    my $timestamp = strftime('%Y%m%d-%H%M%S', localtime);
    my $logfile = $dir->child("$name-$timestamp.log");

    my @lines;
    push @lines, "Deploy: $name at $timestamp";
    push @lines, "=" x 40;
    for my $step (@$steps) {
        my $ok = $self->_ok($step);
        push @lines, sprintf("[%s] %s", $ok ? 'OK' : 'FAIL', $step->{step});
        push @lines, "  $step->{output}" if $step->{output};
    }
    $logfile->spew_utf8(join("\n", @lines) . "\n");
    $self->log->info("Deploy log written to $logfile");
}

1;
