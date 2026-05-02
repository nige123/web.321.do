package Deploy::Service;

use Mojo::Base -base, -signatures;
use Mojo::IOLoop;
use Path::Tiny qw(path);
use POSIX qw(strftime);
use Deploy::Local;
use Deploy::Ubic;

has 'config';     # Deploy::Config instance
has 'log';        # Mojo::Log instance
has 'ubic_mgr';   # Deploy::Ubic instance
has 'transport' => sub { Deploy::Local->new };
has 'filter_to_local' => 0;  # set true on the live dashboard

sub status ($self, $name) {
    my $svc = $self->config->service($name);
    return undef unless $svc;

    my $pid = $self->_get_pid($name, $svc);
    my $git_sha = $self->_git_sha($svc->{repo}, $svc->{branch});
    # skip port check for stopped services — avoids 2s curl timeout each
    my $port_ok = $pid ? $self->_check_port($svc->{port}) : 0;

    return $self->_status_hash($name, $svc, $pid, $git_sha, $port_ok);
}

sub all_status ($self) {
    # one batched `ubic status` instead of one fork per service.
    # ubic exits non-zero when any service is off, so we parse output
    # regardless of $r->{ok}.
    my $r = $self->transport->run("ubic status");
    my $statuses = Deploy::Ubic->parse_status_output($r->{output});

    my @results;
    for my $name (@{ $self->config->service_names }) {
        my $svc = $self->config->service($name);
        next unless $svc;

        # On the live deployment of 321.do, hide services not actually
        # installed on this box — dev-only services would just be noise.
        # On dev we keep them all so the local dashboard can survey both
        # targets via the target switcher.
        next if $self->filter_to_local && !exists $statuses->{$name};

        my $pid = $statuses->{$name}{pid};
        my $git_sha = $self->_git_sha($svc->{repo}, $svc->{branch});
        # port check skipped here — too slow for dashboard hot path
        my $running = $pid ? 1 : 0;

        push @results, $self->_status_hash($name, $svc, $pid, $git_sha, $running);
    }
    return \@results;
}

sub _status_hash ($self, $name, $svc, $pid, $git_sha, $running) {
    return {
        name    => $name,
        pid     => $pid,
        port    => $svc->{port},
        running => $running ? \1 : \0,
        git_sha => $git_sha,
        repo    => $svc->{repo},
        branch  => $svc->{branch},
        mode    => $svc->{mode} // 'production',
        runner  => $svc->{runner} // 'hypnotoad',
        host    => $svc->{host} // 'localhost',
        ($svc->{is_worker} ? (is_worker => 1)                : ()),
        ($svc->{favicon}   ? (favicon   => $svc->{favicon})  : ()),
        ($svc->{docs}      ? (docs      => $svc->{docs})     : ()),
        ($svc->{admin}     ? (admin     => $svc->{admin})    : ()),
    };
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
        # For SSH targets, generate writes to a temp file locally; we then
        # upload it to the remote ~/ubic/service/<group>/<name>. Without this
        # step, changes to perl version, env, or runner in 321.yml would
        # never reach the live ubic wrapper.
        my $is_remote = $self->transport->isa('Deploy::SSH');
        if ($is_remote) {
            $self->ubic_mgr->transport($self->transport);
            $self->ubic_mgr->detect_remote;
        }
        my $gen = $self->ubic_mgr->generate($name);
        $self->ubic_mgr->upload_remote($self->transport, $name, $gen) if $is_remote;
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
    if ($r->{ok}) {
        my $statuses = Deploy::Ubic->parse_status_output($r->{output});
        return $statuses->{$name}{pid} if defined $statuses->{$name}{pid};
    }

    # Fallback: hypnotoad.pid may live in bin/ or repo root
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

sub _git_sha ($self, $repo, $branch = undef) {
    if (defined(my $sha = $self->_git_sha_from_disk($repo, $branch))) {
        return $sha;
    }
    # Fallback for packed refs we can't parse, remote repos, or detached states
    my $r = $self->transport->run_in_dir($repo, 'git rev-parse --short HEAD');
    return undef unless $r->{ok};
    chomp(my $sha = $r->{output});
    return $sha || undef;
}

sub _git_sha_from_disk ($self, $repo, $branch) {
    if (!$branch) {
        my $head_file = path($repo, '.git', 'HEAD');
        return undef unless $head_file->exists;
        my $head = $head_file->slurp;
        return substr($1, 0, 7) if $head =~ /^([0-9a-f]{7,})/;
        return undef unless $head =~ m{^ref: refs/heads/(\S+)};
        $branch = $1;
    }

    my $ref_file = path($repo, '.git', 'refs', 'heads', $branch);
    if ($ref_file->exists) {
        my $sha = $ref_file->slurp;
        $sha =~ s/\s+//g;
        return substr($sha, 0, 7) if length($sha) >= 7;
    }

    # git gc compacts loose refs into .git/packed-refs
    my $packed = path($repo, '.git', 'packed-refs');
    if ($packed->exists) {
        for my $line (split /\n/, $packed->slurp) {
            return substr($1, 0, 7) if $line =~ m{^([0-9a-f]+)\s+refs/heads/\Q$branch\E$};
        }
    }
    return undef;
}

sub _check_port ($self, $port) {
    return 0 unless $port;
    # Drop -f: any HTTP response (200/404/500) means the socket is alive.
    # Apps that only serve under /v3 etc. would 404 on / and falsely fail -f.
    my $r = $self->transport->run("curl -s -o /dev/null --connect-timeout 1 http://127.0.0.1:$port/", timeout => 3);
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
