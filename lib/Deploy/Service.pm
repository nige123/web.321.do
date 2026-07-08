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
    # skip port check for stopped services - avoids 2s curl timeout each
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
        # installed on this box - dev-only services would just be noise.
        # On dev we keep them all so the local dashboard can survey both
        # targets via the target switcher.
        next if $self->filter_to_local && !exists $statuses->{$name};

        my $pid = $statuses->{$name}{pid};
        my $git_sha = $self->_git_sha($svc->{repo}, $svc->{branch});
        # port check skipped here - too slow for dashboard hot path
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

    # Remember where we started so a failed health gate can roll back.
    my ($old_sha, $new_sha);
    unless ($skip_git) {
        $old_sha = $self->_head_sha($svc);
        $s = $self->_step_git_pull($svc);
        push @steps, $s;
        return $self->_deploy_result($name, 'error', 'Git pull failed', \@steps)
            unless $self->_ok($s);
        $new_sha = $self->_head_sha($svc);
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

    # Hypnotoad services whose INSTALLED ubic file is already the
    # self-supervising Common form hot-swap via USR2 - zero downtime, ubic
    # never notices the manager pid change. A service still under
    # SimpleDaemon guardianship must instead be stopped through the OLD file
    # BEFORE the new one is uploaded: with the file already replaced, a
    # Common-style stop would kill the manager but orphan the guardian, which
    # would immediately respawn it. So the decision (and the transition stop)
    # happen before generate_ubic.
    my $is_hypno = !$svc->{is_worker} && ($svc->{runner} // 'hypnotoad') eq 'hypnotoad';
    my $was_hot  = $is_hypno ? $self->_installed_ubic_is_hot($name) : 0;
    my $old_pid  = $was_hot ? $self->_live_hypnotoad_pid($svc) : undef;
    my $hot      = $was_hot && $old_pid;

    my @teardown;
    if ($is_hypno && !$hot) {
        # Cold path: tear down under the currently-installed semantics.
        @teardown = $self->_bounce_teardown_steps($name, $svc);
        push @steps, @teardown;
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

    my ($hot_attempted, $swap_took) = (0, 0);
    if ($hot) {
        $hot_attempted = 1;
        $s = $self->_step_hot_deploy($svc, $old_pid);
        push @steps, $s;
        $swap_took = $self->_ok($s);
        # A swap that never took is a failed deploy, but nothing is down: the
        # previous release kept serving. The gate/rollback below handles it.
    }
    elsif ($is_hypno) {
        # Teardown already ran above; boot through the freshly-installed file.
        $s = $self->_step_ubic_start($name);
        push @steps, $s;
        unless ($self->_ok($s)) {
            return $self->_deploy_result($name, 'error', 'Ubic start failed', \@steps);
        }
    }
    else {
        my @bounce = $self->_bounce_steps($name, $svc);
        push @steps, @bounce;
        unless ($self->_ok($bounce[-1])) {
            my $msg = $svc->{is_worker} ? 'Ubic restart failed' : 'Ubic start failed';
            return $self->_deploy_result($name, 'error', $msg, \@steps);
        }
    }

    # The gate: a declared manifest health path must answer 2xx; otherwise any
    # response on the port will do. Workers have neither - a successful bounce
    # is their success criterion.
    my ($gate_ok, $gate_reason) = (1, '');
    if ($hot_attempted && !$swap_took) {
        ($gate_ok, $gate_reason) = (0, 'the hot swap did not take - the previous release kept serving');
    }
    elsif (!$svc->{is_worker}) {
        my $g = $self->_gate_step($name, $svc);
        push @steps, $g;
        $gate_ok = $self->_ok($g);
        $gate_reason = "$g->{step} failed" unless $gate_ok;
    }

    my $tag = $skip_git ? ' (dev)' : '';

    if ($gate_ok) {
        $self->_log_deploy($name, \@steps);
        return $self->_deploy_result($name, 'success', "Deployed $name$tag successfully", \@steps);
    }

    # Gate failed. Roll back when there is a previous sha to return to.
    if (!$skip_git && $old_sha && $new_sha && $old_sha ne $new_sha) {
        my $recovered = $self->_rollback($name, $svc, \@steps, $old_sha, $hot_attempted, $swap_took);
        $self->_log_deploy($name, \@steps);
        my $short = substr($old_sha, 0, 7);
        return $self->_deploy_result($name,
            $recovered ? 'rolled_back' : 'error',
            $recovered
                ? "Deploy of $name failed ($gate_reason) - rolled back to $short"
                : "Deploy of $name failed ($gate_reason) and the rollback to $short did not recover - check the service",
            \@steps);
    }

    $self->_log_deploy($name, \@steps);
    return $self->_deploy_result($name, 'error', "Deployed $name$tag but $gate_reason", \@steps);
}

# Restore the repo to $old_sha and put the previous release back in service.
# Appends its steps to @$steps; returns 1 when the service answers its gate
# again afterwards.
sub _rollback ($self, $name, $svc, $steps, $old_sha, $hot_attempted, $swap_took) {
    my $r = $self->_run_in_dir($svc->{repo}, "git reset --hard $old_sha");
    push @$steps, { step => 'rollback_git', success => $r->{ok} ? \1 : \0, output => $r->{output} };
    return 0 unless $r->{ok};

    my $s = $self->_step_cpanm($svc);
    push @$steps, { %$s, step => 'rollback_cpanm' };

    if ($hot_attempted && $swap_took) {
        # The bad release is serving - swap once more, now that the repo holds
        # the old code again.
        my $cur = $self->_live_hypnotoad_pid($svc);
        if ($cur) {
            $s = $self->_step_hot_deploy($svc, $cur, 'rollback_swap');
            push @$steps, $s;
            return 0 unless $self->_ok($s);
        }
        else {
            push @$steps, { step => 'rollback_swap', success => \0,
                output => 'no live manager found to swap back' };
            return 0;
        }
    }
    elsif ($hot_attempted && !$swap_took) {
        # The old release never stopped serving; the repo reset is the fix.
        push @$steps, { step => 'rollback_swap', success => \1,
            output => 'previous release kept serving - no swap needed' };
    }
    else {
        my @bounce = $self->_bounce_steps($name, $svc);
        push @$steps, @bounce;
        return 0 unless $self->_ok($bounce[-1]);
    }

    my $g = $self->_gate_step($name, $svc);
    push @$steps, { %$g, step => "rollback_$g->{step}" };
    return $self->_ok($g);
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
    my $port = $svc->{port};
    return { step => 'port_check', success => \1, output => "Port $port responding" }
        if $self->_check_port($port);

    my $output = "Port $port not responding";
    # Common cause for hypnotoad services: the app's own config binds a
    # different port than the 321 manifest declares. hypnotoad takes its
    # listen port from app->config->{hypnotoad}{listen}, which 321 can't pass
    # on the command line - so if the app is up on some other port, say so.
    if (($svc->{runner} // 'hypnotoad') eq 'hypnotoad') {
        my $bound = $self->_logged_listen_port($svc);
        if ($bound && $bound != $port && $self->_check_port($bound)) {
            $output .= " - the app is actually serving on $bound."
                     . "  Add  'hypnotoad' => { listen => ['http://*:$port'] }  to the"
                     . " app's production config so it matches the 321 manifest.";
        }
    }
    return { step => 'port_check', success => \0, output => $output };
}

# Last "Listening at http://...:PORT" line in the service's stderr log, or
# undef. Used only to explain a port_check failure.
sub _logged_listen_port ($self, $svc) {
    my $log = ($svc->{logs} // {})->{stderr} or return undef;
    my $r = $self->transport->run(
        qq{grep -oE 'Listening at "http://[^"]+"' '$log' 2>/dev/null | tail -1}
    );
    return undef unless $r->{ok} && defined $r->{output};
    my ($p) = $r->{output} =~ /:(\d+)"/;
    return $p;
}

sub deploy_dev ($self, $name) {
    return $self->deploy($name, skip_git => 1);
}

# Full sha of the repo's current HEAD on the deploy target, or undef.
sub _head_sha ($self, $svc) {
    my $r = $self->_run_in_dir($svc->{repo}, 'git rev-parse HEAD');
    return undef unless $r->{ok};
    my ($sha) = ($r->{output} // '') =~ /([0-9a-f]{40})/;
    return $sha;
}

# True when the installed ubic service file is the self-supervising Common
# form. A service still under SimpleDaemon guardianship must never be USR2'd:
# the guardian sees its child exit mid-swap and restarts over the top.
sub _installed_ubic_is_hot ($self, $name) {
    my ($group, $svc_name) = split /\./, $name, 2;
    my $r = $self->_run_cmd("cat ~/ubic/service/$group/$svc_name 2>/dev/null");
    return ($r->{output} // '') =~ /Ubic::Service::Common/ ? 1 : 0;
}

# Pid from hypnotoad's own pidfile, iff that process is alive. Runs on the
# deploy target (local or SSH), so no direct kill(0) here.
sub _live_hypnotoad_pid ($self, $svc) {
    my $pidfile = $svc->{pid_file} or return undef;
    my $r = $self->_run_cmd(
        qq{p=\$(cat '$pidfile' 2>/dev/null); [ -n "\$p" ] && kill -0 "\$p" 2>/dev/null && echo "\$p"});
    return undef unless $r->{ok};
    my ($pid) = ($r->{output} // '') =~ /^\s*(\d+)\s*$/;
    return $pid;
}

# Zero-downtime swap: USR2 tells the running manager to exec a fresh copy of
# itself on the current repo code; the old workers drain while the new ones
# take over the socket. Success = the pidfile now names a different live
# manager. If it never changes, the new code failed to boot and hypnotoad
# kept the previous release serving - report failure, nothing is down.
sub _step_hot_deploy ($self, $svc, $old_pid, $label = 'hot_deploy') {
    my $r = $self->_run_cmd("kill -USR2 $old_pid");
    return { step => $label, success => \0, output => "USR2 to $old_pid failed: $r->{output}" }
        unless $r->{ok};

    for my $poll (1 .. 30) {
        $self->_sleep(1);
        my $pid = $self->_live_hypnotoad_pid($svc);
        if ($pid && $pid ne $old_pid) {
            return { step => $label, success => \1,
                output => "manager $old_pid -> $pid (zero downtime)" };
        }
    }
    return { step => $label, success => \0,
        output => 'manager pid unchanged after USR2 - the upgrade did not take; '
                . 'the previous release kept serving' };
}

# Post-deploy gate. A health path declared in the manifest is authoritative:
# it must answer 2xx. Undeclared health falls back to the port check (any
# response), because probing a default /health an app never implemented
# would fail every deploy.
sub _gate_step ($self, $name, $svc) {
    my $declared = $self->_declared_health($name);
    return $self->_step_health_check($svc, $declared) if defined $declared;
    $self->_sleep(2);
    return $self->_step_port_check($svc);
}

sub _declared_health ($self, $name) {
    my $raw = $self->config->service_raw($name) or return undef;
    return $raw->{health};
}

sub _step_health_check ($self, $svc, $path, $attempts = 10) {
    my $port = $svc->{port};
    my $url  = "http://127.0.0.1:$port$path";
    for my $i (1 .. $attempts) {
        my $r = $self->_run_cmd("curl -sf -o /dev/null --connect-timeout 1 $url");
        return { step => 'health_check', success => \1,
            output => "GET $path on :$port healthy" } if $r->{ok};
        $self->_sleep(1) unless $i == $attempts;
    }
    return { step => 'health_check', success => \0,
        output => "GET $path on :$port failed after $attempts attempts" };
}

sub restart ($self, $name) {
    my $svc = $self->config->service($name);
    return { status => 'error', message => "Unknown service: $name" } unless $svc;

    my @steps = $self->_bounce_steps($name, $svc);
    unless ($self->_ok($steps[-1])) {
        my $msg = $svc->{is_worker} ? 'Ubic restart failed' : 'Ubic start failed';
        return $self->_deploy_result($name, 'error', $msg, \@steps);
    }

    # Workers have no port - a clean bounce is the whole story.
    if ($svc->{is_worker}) {
        return $self->_deploy_result($name, 'success', "Restarted $name", \@steps);
    }

    $self->_sleep(2);
    my $pc = $self->_step_port_check($svc);
    push @steps, $pc;

    my $port_ok = $self->_ok($pc);
    return $self->_deploy_result(
        $name,
        $port_ok ? 'success' : 'error',
        $port_ok ? "Restarted $name" : 'Port check failed after restart',
        \@steps,
    );
}

# Bounce a service so ubic stays its sole supervisor. A bare `ubic restart`
# (stop+start, no coordination) races the still-draining old manager:
# `hypnotoad -f` finds the previous bin/hypnotoad.pid alive, sends it USR2
# (hot deploy) and exits - so the PID never changes ("phantom restart"), or
# the port is still bound ("Address already in use"). Instead: stop, wait for
# the port to actually free, clear hypnotoad's own pidfile, then start clean.
# Returns the ordered step list; the caller reads $steps[-1] for success.
# Workers (no port, no pidfile) get a plain in-place `ubic restart`.
sub _bounce_steps ($self, $name, $svc) {
    return ($self->_step_ubic_restart($name)) if $svc->{is_worker};
    my @steps = $self->_bounce_teardown_steps($name, $svc);
    push @steps, $self->_step_ubic_start($name);
    return @steps;
}

# The stop half of the bounce: stop -> wait for the port to free -> clear
# hypnotoad's pidfile. Split out so a deploy that replaces the ubic service
# file can tear down under the OLD file's semantics and start under the new.
sub _bounce_teardown_steps ($self, $name, $svc) {
    my @steps = $self->_step_ubic_stop($name);  # a failed stop usually just means "already down"

    if (my $port = $svc->{port}) {
        my $freed = $self->_wait_port_free($port);
        push @steps, {
            step    => 'port_drain',
            success => $freed ? \1 : \0,
            output  => $freed ? "Port $port freed"
                              : "Port $port still bound after stop - starting anyway",
        };
    }

    $self->_clear_hypnotoad_pid($svc)
        if ($svc->{runner} // 'hypnotoad') eq 'hypnotoad';

    return @steps;
}

sub _step_ubic_stop ($self, $name) {
    my $r = $self->_run_cmd("ubic stop $name");
    return { step => 'ubic_stop', success => $r->{ok} ? \1 : \0, output => $r->{output} };
}

sub _step_ubic_start ($self, $name) {
    my $r = $self->_run_cmd("ubic start $name");
    return { step => 'ubic_start', success => $r->{ok} ? \1 : \0, output => $r->{output} };
}

# Poll until nothing answers on $port (the old workers have released it), or
# until $timeout polls have elapsed. Returns 1 if freed, 0 if it gave up.
sub _wait_port_free ($self, $port, $timeout = 15) {
    return 1 unless $port;
    my $slept = 0;
    while (1) {
        return 1 unless $self->_check_port($port);
        last if $slept >= $timeout;
        $self->_sleep(1);
        $slept++;
    }
    return 0;
}

# Remove hypnotoad's own pidfile so the next `hypnotoad -f` can't mistake a
# half-dead manager for a live one and degrade into a USR2 hot-deploy. The
# pidfile lives next to the entry script (default) or at the repo root.
sub _clear_hypnotoad_pid ($self, $svc) {
    my $repo = $svc->{repo} or return;
    my @rel = ('bin/hypnotoad.pid', 'hypnotoad.pid');
    if (($svc->{bin} // '') =~ m{^(.+)/}) {
        unshift @rel, "$1/hypnotoad.pid";
    }
    my %seen;
    my @paths = grep { !$seen{$_}++ } map { "$repo/$_" } @rel;
    $self->_run_cmd('rm -f ' . join(' ', @paths));
}

# Indirection so tests can run the restart sequence without real sleeps.
sub _sleep ($self, $seconds) { sleep $seconds }

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
