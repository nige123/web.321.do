# Worker Lifecycle Cascade Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `321 go`, `321 start`, `321 stop`, and `321 restart` treat a service + its declared workers as one unit when the main service is named.

**Architecture:** One Config helper (`workers_of`) and one Command helper (`cascade_workers`) that runs `ubic <action> <worker>` for each worker on a given transport. Each lifecycle command calls the cascade helper after (or before, for stop) its existing main-service action. Cascade is gated on the main step succeeding; per-worker failures are reported and the cascade continues.

**Tech Stack:** Perl 5.42 with Mojo::Base signatures, Mojolicious::Command for CLI subcommands, ubic for process supervision, `Path::Tiny::tempdir` fixtures for tests, `prove -lr t` to run tests.

**Repo policy reminders for every commit step:**
- No `Co-Authored-By` or AI-attribution trailers (CLAUDE.md global).
- Push after every commit in this repo (memory).
- Subject + body only; pass body via HEREDOC.

**Test file convention:** All cascade tests live in `t/40-worker-cascade.t`. It is built up across Tasks 1, 2, 3, 4, 5, 6 — each task appends its own `subtest` block.

**Fixture pattern:** The fixture helper at the top of `t/40-worker-cascade.t` mirrors `t/27-service-lifecycle.t`'s `make_fixture` and adds a `workers:` block.

---

## File Structure

**Modified:**
- `lib/Deploy/Config.pm` — add `workers_of` method
- `lib/Deploy/Command.pm` — add `cascade_workers` helper
- `lib/Deploy/Command/stop.pm` — cascade workers (reverse) before main
- `lib/Deploy/Command/restart.pm` — cascade workers after main on success
- `lib/Deploy/Command/start.pm` — refactor `_start_one` to return started?, then cascade
- `lib/Deploy/Command/go.pm` — cascade workers after main redeploy on success
- `CLAUDE.md` — document the cascade
- `AGENT.md` — document the cascade
- `/home/nige/.claude/skills/using-321/SKILL.md` — document the cascade

**Created:**
- `t/40-worker-cascade.t` — all new tests
- `docs/superpowers/plans/2026-05-30-worker-lifecycle-cascade.md` — this file

---

## Task 1: `Config::workers_of` helper

Adds the only piece of new model logic. Returns the worker service names for a main, `[]` for anything else.

**Files:**
- Create: `t/40-worker-cascade.t`
- Modify: `lib/Deploy/Config.pm`

- [ ] **Step 1: Write the failing test**

Write `t/40-worker-cascade.t`:

```perl
use strict;
use warnings;
use Test::More;
use Path::Tiny qw(tempdir path);
use Deploy::Config;
use Mojo::Log;

# Fixture: a scan_dir containing one repo whose 321.yml declares two workers
# (printer, mailer) plus a no-workers control repo. Returns the scan_dir path
# and the tempdir handles to keep them alive.
sub make_fixture {
    my $home_obj = tempdir(CLEANUP => 1);
    my $scan_obj = tempdir(CLEANUP => 1);

    my $repo = path($scan_obj, 'web.demo.do');
    $repo->mkpath;
    system("cd $repo && git init -q && git config user.email t\@t && git config user.name t && git commit --allow-empty -m init -q");
    path($repo, '321.yml')->spew_utf8(<<'YAML');
name: demo.web
entry: bin/app.pl
runner: hypnotoad
workers:
  printer:
    cmd: bin/printer-worker.pl
  mailer:
    cmd: bin/mailer-worker.pl
live:
  host: demo.do
  port: 39400
  runner: hypnotoad
YAML

    my $plain = path($scan_obj, 'web.plain.do');
    $plain->mkpath;
    system("cd $plain && git init -q && git config user.email t\@t && git config user.name t && git commit --allow-empty -m init -q");
    path($plain, '321.yml')->spew_utf8(<<'YAML');
name: plain.web
entry: bin/app.pl
runner: hypnotoad
live:
  host: plain.do
  port: 39401
  runner: hypnotoad
YAML

    return ("$home_obj", "$scan_obj", $scan_obj, $home_obj);
}

subtest 'workers_of returns sorted worker names for a main with workers' => sub {
    my ($home, $scan, $scan_obj, $home_obj) = make_fixture();
    my $cfg = Deploy::Config->new(app_home => $home, scan_dir => $scan, target => 'live');
    is_deeply $cfg->workers_of('demo.web'), ['demo.mailer', 'demo.printer'],
        'returns sorted [demo.mailer, demo.printer]';
};

subtest 'workers_of returns [] for a worker name' => sub {
    my ($home, $scan, $scan_obj, $home_obj) = make_fixture();
    my $cfg = Deploy::Config->new(app_home => $home, scan_dir => $scan, target => 'live');
    is_deeply $cfg->workers_of('demo.printer'), [], 'worker target → empty list';
};

subtest 'workers_of returns [] for a main with no workers' => sub {
    my ($home, $scan, $scan_obj, $home_obj) = make_fixture();
    my $cfg = Deploy::Config->new(app_home => $home, scan_dir => $scan, target => 'live');
    is_deeply $cfg->workers_of('plain.web'), [], 'no workers: → empty list';
};

subtest 'workers_of returns [] for an unknown name' => sub {
    my ($home, $scan, $scan_obj, $home_obj) = make_fixture();
    my $cfg = Deploy::Config->new(app_home => $home, scan_dir => $scan, target => 'live');
    is_deeply $cfg->workers_of('nope.web'), [], 'unknown → empty list';
};

done_testing;
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `prove -lv t/40-worker-cascade.t`
Expected: FAIL with `Can't locate object method "workers_of" via package "Deploy::Config"`.

- [ ] **Step 3: Implement `workers_of`**

Open `lib/Deploy/Config.pm`. Locate the `services` method (around line 70). Add this method immediately after `service_names` (around line 118-120):

```perl
sub workers_of ($self, $name) {
    $self->_check_reload;
    my $manifest = $self->_services->{$name};
    return [] unless $manifest;
    return [] if exists $manifest->{_parent};   # this entry is a worker, not a main
    my $workers = $manifest->{workers} // {};
    my ($group) = split /\./, $name, 2;
    return [ map { "$group.$_" } sort keys %$workers ];
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `prove -lv t/40-worker-cascade.t`
Expected: all 4 subtests pass.

- [ ] **Step 5: Run the full test suite — nothing else regresses**

Run: `prove -lr t`
Expected: all tests pass.

- [ ] **Step 6: Commit and push**

```bash
git add t/40-worker-cascade.t lib/Deploy/Config.pm
git commit -m "$(cat <<'EOF'
Config: workers_of(name) returns the worker service names

Returns sorted '<group>.<workerName>' names for a main with a
workers: block, or [] for a worker / a main without workers /
unknown names. Foundation for the lifecycle cascade.
EOF
)"
git push
```

---

## Task 2: `Deploy::Command::cascade_workers` helper

Single helper called by every lifecycle subcommand. Runs `ubic <action> <worker>` for each worker, returning a per-worker result list. Pure transport plumbing — no print statements, no app coupling beyond `config`.

**Files:**
- Modify: `lib/Deploy/Command.pm`
- Modify: `t/40-worker-cascade.t`

- [ ] **Step 1: Add the failing test**

Append to `t/40-worker-cascade.t` (before `done_testing`):

```perl
# Lightweight transport double that records every command run against it
# and returns canned replies keyed by exact command string.
package RecordingTransport {
    sub new {
        my ($class, %args) = @_;
        return bless {
            calls   => [],
            replies => $args{replies} // {},
            default => $args{default} // { ok => 1, output => '' },
        }, $class;
    }
    sub run {
        my ($self, $cmd, %opts) = @_;
        push @{ $self->{calls} }, $cmd;
        return $self->{replies}{$cmd} // $self->{default};
    }
    sub calls { @{ $_[0]{calls} } }
    sub isa  { 0 }
}

# Build a Mojolicious app whose config_obj is the fixture Deploy::Config,
# so Deploy::Command->new(app => $app)->config works.
sub make_app {
    my ($cfg) = @_;
    require Mojolicious;
    my $app = Mojolicious->new;
    $app->attr(config_obj => sub { $cfg });
    return $app;
}

subtest 'cascade_workers runs ubic <action> on every worker in sorted order' => sub {
    my ($home, $scan, $scan_obj, $home_obj) = make_fixture();
    my $cfg = Deploy::Config->new(app_home => $home, scan_dir => $scan, target => 'live');
    require Deploy::Command;
    my $cmd = Deploy::Command->new(app => make_app($cfg));
    my $t = RecordingTransport->new;
    my $results = $cmd->cascade_workers('demo.web', 'restart', $t);
    is_deeply [$t->calls],
        ['ubic restart demo.mailer', 'ubic restart demo.printer'],
        'one ubic restart per worker, sorted order';
    is scalar @$results, 2, 'two result rows';
    is $results->[0]{name}, 'demo.mailer', 'first result names mailer';
    ok  $results->[0]{ok},                 'first result reports ok';
};

subtest 'cascade_workers reverses for stop' => sub {
    my ($home, $scan, $scan_obj, $home_obj) = make_fixture();
    my $cfg = Deploy::Config->new(app_home => $home, scan_dir => $scan, target => 'live');
    my $cmd = Deploy::Command->new(app => make_app($cfg));
    my $t = RecordingTransport->new;
    $cmd->cascade_workers('demo.web', 'stop', $t);
    is_deeply [$t->calls],
        ['ubic stop demo.printer', 'ubic stop demo.mailer'],
        'stop iterates reverse of the sorted list';
};

subtest 'cascade_workers continues after a per-worker failure' => sub {
    my ($home, $scan, $scan_obj, $home_obj) = make_fixture();
    my $cfg = Deploy::Config->new(app_home => $home, scan_dir => $scan, target => 'live');
    my $cmd = Deploy::Command->new(app => make_app($cfg));
    my $t = RecordingTransport->new(replies => {
        'ubic restart demo.mailer' => { ok => 0, output => 'boom' },
    });
    my $results = $cmd->cascade_workers('demo.web', 'restart', $t);
    is_deeply [$t->calls],
        ['ubic restart demo.mailer', 'ubic restart demo.printer'],
        'second worker still attempted after first failed';
    ok !$results->[0]{ok}, 'mailer result marked failed';
    is $results->[0]{output}, 'boom', 'failure output captured';
    ok  $results->[1]{ok}, 'printer result still ok';
};

subtest 'cascade_workers is a no-op when target has no workers' => sub {
    my ($home, $scan, $scan_obj, $home_obj) = make_fixture();
    my $cfg = Deploy::Config->new(app_home => $home, scan_dir => $scan, target => 'live');
    my $cmd = Deploy::Command->new(app => make_app($cfg));
    my $t = RecordingTransport->new;
    my $results = $cmd->cascade_workers('plain.web', 'restart', $t);
    is_deeply [$t->calls], [], 'no transport calls made';
    is_deeply $results, [], 'empty result list';
};
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `prove -lv t/40-worker-cascade.t`
Expected: the four new subtests fail with `Can't locate object method "cascade_workers" via package "Deploy::Command"`.

- [ ] **Step 3: Implement `cascade_workers` in `Deploy::Command`**

Open `lib/Deploy/Command.pm`. Add this method below `print_failure` (after line 238, before `1;`):

```perl
# Run "ubic <action> <worker>" on the given transport for every worker
# belonging to the main service $name. For 'stop', the worker list is
# reversed so workers settle before the main. Returns an arrayref of
# { name, ok, output } rows — one per worker step. A per-worker failure
# is recorded; the loop keeps going.
sub cascade_workers ($self, $name, $action, $transport) {
    my $workers = $self->config->workers_of($name);
    return [] unless @$workers;
    my @order = $action eq 'stop' ? reverse @$workers : @$workers;
    my @results;
    for my $w (@order) {
        my $r = $transport->run("ubic $action $w");
        push @results, {
            name   => $w,
            ok     => $r->{ok} ? 1 : 0,
            output => $r->{output} // '',
        };
    }
    return \@results;
}

# Pretty-print one cascade result row to STDOUT (used by lifecycle subcommands).
sub print_worker_step ($self, $action, $row) {
    if ($row->{ok}) {
        printf "  [OK] worker %s %sed\n", $row->{name}, $action;
    } else {
        printf "  [FAIL] worker %s %s — %s\n", $row->{name}, $action, $row->{output};
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `prove -lv t/40-worker-cascade.t`
Expected: all subtests now pass (including the Task 1 ones).

- [ ] **Step 5: Commit and push**

```bash
git add lib/Deploy/Command.pm t/40-worker-cascade.t
git commit -m "$(cat <<'EOF'
Command: cascade_workers helper + print_worker_step

cascade_workers(name, action, transport) runs 'ubic <action> <worker>'
for every worker under the named main service, returning a row per
worker. Stop iterates in reverse. Lifecycle subcommands will call this
after (or before, for stop) their main-service action.
EOF
)"
git push
```

---

## Task 3: `321 stop` cascades to workers

Stop is the simplest cascade integration (no "did main start" gating). Workers stop before the main; per-worker failures don't abort the cascade or the main stop.

**Files:**
- Modify: `lib/Deploy/Command/stop.pm`
- Modify: `t/40-worker-cascade.t`

- [ ] **Step 1: Add the failing test**

Append to `t/40-worker-cascade.t` before `done_testing`:

```perl
# Stubbed stop subclass that swaps in a recording transport and skips
# the status command at the end of stop.pm (status would re-instantiate
# its own transport_for and we want to assert on the one we injected).
package TestStop {
    use parent -norequire, 'Deploy::Command::stop';
    our $TRANSPORT;
    sub transport_for { $TRANSPORT }
    # Skip the trailing status block; it constructs a real Mojolicious
    # status command which isn't what these tests are about.
    sub _show_status { }
}

subtest 'stop demo.web stops workers in reverse, then main' => sub {
    my ($home, $scan, $scan_obj, $home_obj) = make_fixture();
    my $cfg = Deploy::Config->new(app_home => $home, scan_dir => $scan, target => 'live');
    my $t = RecordingTransport->new;
    local $TestStop::TRANSPORT = $t;
    my $cmd = TestStop->new(app => make_app($cfg));
    $cmd->run('demo.web', 'live');
    is_deeply [$t->calls],
        ['ubic stop demo.printer', 'ubic stop demo.mailer', 'ubic stop demo.web'],
        'workers stop reverse-sorted, then main';
};

subtest 'stop demo.printer (worker target) does not cascade' => sub {
    my ($home, $scan, $scan_obj, $home_obj) = make_fixture();
    my $cfg = Deploy::Config->new(app_home => $home, scan_dir => $scan, target => 'live');
    my $t = RecordingTransport->new;
    local $TestStop::TRANSPORT = $t;
    my $cmd = TestStop->new(app => make_app($cfg));
    $cmd->run('demo.printer', 'live');
    is_deeply [$t->calls], ['ubic stop demo.printer'],
        'naming a worker stops only that worker';
};

subtest 'stop continues to main even when a worker stop fails' => sub {
    my ($home, $scan, $scan_obj, $home_obj) = make_fixture();
    my $cfg = Deploy::Config->new(app_home => $home, scan_dir => $scan, target => 'live');
    my $t = RecordingTransport->new(replies => {
        'ubic stop demo.printer' => { ok => 0, output => 'boom' },
    });
    local $TestStop::TRANSPORT = $t;
    my $cmd = TestStop->new(app => make_app($cfg));
    $cmd->run('demo.web', 'live');
    is_deeply [$t->calls],
        ['ubic stop demo.printer', 'ubic stop demo.mailer', 'ubic stop demo.web'],
        'failed worker does not abort cascade or main';
};
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `prove -lv t/40-worker-cascade.t`
Expected: the three new subtests fail — actual calls don't include worker stops.

- [ ] **Step 3: Edit `stop.pm` to cascade**

Replace the body of `lib/Deploy/Command/stop.pm` with:

```perl
package Deploy::Command::stop;

use Mojo::Base 'Deploy::Command', -signatures;

has description => 'Stop a service';
has usage => sub ($self) { $self->extract_usage };

sub run ($self, @args) {
    my ($svc_input, $target) = $self->parse_target(@args);
    die $self->usage unless $svc_input;
    my @names = $self->resolve_service($svc_input);
    $self->config->target($target);

    for my $name (@names) {
        my $transport = $self->transport_for($name, $target);

        # Stop workers first (reverse sorted) so they settle before the main
        # process exits. No-op when $name resolves to a worker or to a main
        # with no workers — cascade_workers returns [] in those cases.
        for my $row (@{ $self->cascade_workers($name, 'stop', $transport) }) {
            $self->print_worker_step('stop', $row);
        }

        my $r = $transport->run("ubic stop $name");
        if ($r->{ok}) {
            say "  $name stopped ($target)";
        } else {
            say "  $name stop failed: $r->{output}";
        }
    }

    $self->_show_status($svc_input, $target);
}

sub _show_status ($self, $svc_input, $target) {
    say "";
    require Deploy::Command::status;
    Deploy::Command::status->new(app => $self->app)->run($svc_input, $target);
}

1;

=head1 SYNOPSIS

  Usage: APPLICATION stop <service>

  Stops the named service. When the name is a main service with workers
  declared in its 321.yml, workers are stopped first (reverse sorted),
  then the main. Naming a worker directly stops only that worker.

=cut
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `prove -lv t/40-worker-cascade.t`
Expected: all subtests pass.

- [ ] **Step 5: Run the full suite**

Run: `prove -lr t`
Expected: all tests pass.

- [ ] **Step 6: Commit and push**

```bash
git add lib/Deploy/Command/stop.pm t/40-worker-cascade.t
git commit -m "$(cat <<'EOF'
stop: cascade to workers in reverse sorted order

'321 stop <main>' now stops every worker declared under the main's
321.yml before stopping the main process — workers in reverse sorted
order so jobs settle before the connection they depend on goes away.
Naming a worker directly stops just that worker.

Failed worker stops are reported but don't abort the cascade or the
main stop; an operator can investigate from the status output.
EOF
)"
git push
```

---

## Task 4: `321 restart` cascades to workers after main on success

Restart is the next-simplest: the existing `Service::restart` returns `{status => 'success' | 'error', ...}`. Cascade only if success.

**Files:**
- Modify: `lib/Deploy/Command/restart.pm`
- Modify: `t/40-worker-cascade.t`

- [ ] **Step 1: Add the failing test**

Append to `t/40-worker-cascade.t` before `done_testing`:

```perl
# Stub restart subclass: swap transport, swap svc_mgr for one whose restart
# returns a canned result so we can drive the cascade gate.
package StubSvcMgr {
    sub new { bless { result => $_[1] }, $_[0] }
    sub transport { }
    sub restart   { $_[0]->{result} }
}

package TestRestart {
    use parent -norequire, 'Deploy::Command::restart';
    our ($TRANSPORT, $SVC_MGR);
    sub transport_for      { $TRANSPORT }
    sub svc_mgr            { $SVC_MGR }
    sub ensure_fresh_ubic  { }     # skip ubic file freshness check
    sub print_failure      { }     # silence
}

subtest 'restart demo.web cascades after main success' => sub {
    my ($home, $scan, $scan_obj, $home_obj) = make_fixture();
    my $cfg = Deploy::Config->new(app_home => $home, scan_dir => $scan, target => 'live');
    my $t = RecordingTransport->new;
    local $TestRestart::TRANSPORT = $t;
    local $TestRestart::SVC_MGR = StubSvcMgr->new({
        status => 'success', message => 'restarted', data => { steps => [] },
    });
    my $cmd = TestRestart->new(app => make_app($cfg));
    $cmd->run('demo.web', 'live');
    is_deeply [$t->calls],
        ['ubic restart demo.mailer', 'ubic restart demo.printer'],
        'workers restart after main, sorted order';
};

subtest 'restart demo.web does not cascade when main restart errors' => sub {
    my ($home, $scan, $scan_obj, $home_obj) = make_fixture();
    my $cfg = Deploy::Config->new(app_home => $home, scan_dir => $scan, target => 'live');
    my $t = RecordingTransport->new;
    local $TestRestart::TRANSPORT = $t;
    local $TestRestart::SVC_MGR = StubSvcMgr->new({
        status => 'error', message => 'nope', data => { steps => [] },
    });
    my $cmd = TestRestart->new(app => make_app($cfg));
    $cmd->run('demo.web', 'live');
    is_deeply [$t->calls], [], 'main errored → cascade skipped';
};

subtest 'restart demo.printer (worker target) does not cascade' => sub {
    my ($home, $scan, $scan_obj, $home_obj) = make_fixture();
    my $cfg = Deploy::Config->new(app_home => $home, scan_dir => $scan, target => 'live');
    my $t = RecordingTransport->new;
    local $TestRestart::TRANSPORT = $t;
    local $TestRestart::SVC_MGR = StubSvcMgr->new({
        status => 'success', message => 'restarted', data => { steps => [] },
    });
    my $cmd = TestRestart->new(app => make_app($cfg));
    $cmd->run('demo.printer', 'live');
    is_deeply [$t->calls], [], 'worker name → cascade_workers returns []';
};
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `prove -lv t/40-worker-cascade.t`
Expected: the three new subtests fail — calls list is empty for the cascade case.

- [ ] **Step 3: Edit `restart.pm` to cascade on success**

Replace `lib/Deploy/Command/restart.pm` with:

```perl
package Deploy::Command::restart;

use Mojo::Base 'Deploy::Command', -signatures;

has description => 'Restart a service';
has usage => sub ($self) { $self->extract_usage };

sub run ($self, @args) {
    my ($svc_input, $target) = $self->parse_target(@args);
    die $self->usage unless $svc_input;
    my @names = $self->resolve_service($svc_input);
    $self->config->target($target);

    for my $name (@names) {
        my $transport = $self->transport_for($name, $target);
        $self->ensure_fresh_ubic($name, $transport);
        my $svc_mgr = $self->svc_mgr;
        $svc_mgr->transport($transport);
        my $r = $svc_mgr->restart($name);
        $self->print_steps($r);
        if ($r->{status} eq 'success') {
            my $svc  = $self->config->service($name);
            my $port = $svc->{port} // '?';
            my $url  = $self->service_url($svc);
            say "  $r->{message}  port:$port  $url";

            # Cascade worker restarts after main succeeded. No-op when
            # $name is a worker or has no workers.
            for my $row (@{ $self->cascade_workers($name, 'restart', $transport) }) {
                $self->print_worker_step('restart', $row);
            }
        } else {
            $self->print_failure($transport, $name, $target, $r->{message});
        }
    }
}

1;

=head1 SYNOPSIS

  Usage: APPLICATION restart <service>

  Restarts the named service. When the name is a main with workers
  declared in 321.yml, every worker is restarted (ubic restart) after
  the main restart succeeds. Naming a worker directly restarts only
  that worker.

=cut
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `prove -lv t/40-worker-cascade.t`
Expected: all subtests pass.

- [ ] **Step 5: Commit and push**

```bash
git add lib/Deploy/Command/restart.pm t/40-worker-cascade.t
git commit -m "$(cat <<'EOF'
restart: cascade workers after main success

'321 restart <main>' now restarts every worker declared under the
main's 321.yml after the main restart reports success. Worker
failures are surfaced but don't abort the cascade. If the main
restart errors, workers are left alone.
EOF
)"
git push
```

---

## Task 5: `321 start` cascades to workers after main starts

Start needs a small refactor: `_start_one` currently emits to STDOUT and returns nothing. We need it to also return whether the service ended up running, so the cascade can be gated on it.

**Files:**
- Modify: `lib/Deploy/Command/start.pm`
- Modify: `t/40-worker-cascade.t`

- [ ] **Step 1: Add the failing test**

Append to `t/40-worker-cascade.t` before `done_testing`:

```perl
# Reuse the recording transport. For start, we need ubic status to report
# "running" (so the main is considered up) and ubic start to succeed.
package TestStart {
    use parent -norequire, 'Deploy::Command::start';
    our $TRANSPORT;
    sub transport_for     { $TRANSPORT }
    sub ensure_fresh_ubic { }
    # Skip the trailing status command (it constructs its own command).
    sub _show_status      { }
}

# Helper: a recording transport whose ubic status replies say "running",
# so _start_one's "already running" branch fires for the main and workers
# — which still records a 'ubic status' call we can assert on.
sub start_transport_for_already_running {
    return RecordingTransport->new(replies => {
        'ubic status demo.web 2>&1'     => { ok => 1, output => "demo.web\trunning (pid 1234)\n" },
        'ubic status demo.mailer 2>&1'  => { ok => 1, output => "demo.mailer\trunning (pid 1235)\n" },
        'ubic status demo.printer 2>&1' => { ok => 1, output => "demo.printer\trunning (pid 1236)\n" },
    });
}

subtest 'start demo.web cascades to workers in sorted order' => sub {
    my ($home, $scan, $scan_obj, $home_obj) = make_fixture();
    my $cfg = Deploy::Config->new(app_home => $home, scan_dir => $scan, target => 'live');
    my $t = start_transport_for_already_running();
    local $TestStart::TRANSPORT = $t;
    my $cmd = TestStart->new(app => make_app($cfg));
    $cmd->run('demo.web', 'live');
    # Each _start_one runs `ubic status <name> 2>&1` first; if already
    # running, it returns and doesn't call `ubic start`. So the recorded
    # calls are three status checks: main, then workers sorted.
    is_deeply [$t->calls],
        [
            'ubic status demo.web 2>&1',
            'ubic status demo.mailer 2>&1',
            'ubic status demo.printer 2>&1',
        ],
        'main then each worker — sorted';
};

subtest 'start demo.printer (worker target) does not cascade' => sub {
    my ($home, $scan, $scan_obj, $home_obj) = make_fixture();
    my $cfg = Deploy::Config->new(app_home => $home, scan_dir => $scan, target => 'live');
    my $t = start_transport_for_already_running();
    local $TestStart::TRANSPORT = $t;
    my $cmd = TestStart->new(app => make_app($cfg));
    $cmd->run('demo.printer', 'live');
    is_deeply [$t->calls], ['ubic status demo.printer 2>&1'],
        'worker target → only that worker is started';
};

subtest 'start demo.web skips worker cascade if main does not come up' => sub {
    my ($home, $scan, $scan_obj, $home_obj) = make_fixture();
    my $cfg = Deploy::Config->new(app_home => $home, scan_dir => $scan, target => 'live');
    # Main status: not running; ubic start fails (service not installed).
    my $t = RecordingTransport->new(replies => {
        'ubic status demo.web 2>&1' => { ok => 1, output => "demo.web\tnot running\n" },
        'ubic start demo.web'       => { ok => 1, output => 'unknown service demo.web' },
    });
    local $TestStart::TRANSPORT = $t;
    my $cmd = TestStart->new(app => make_app($cfg));
    $cmd->run('demo.web', 'live');
    my @calls = $t->calls;
    ok !(grep { /ubic status demo\.mailer/ } @calls),
        'workers not touched when main fails to start';
};
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `prove -lv t/40-worker-cascade.t`
Expected: the new subtests fail — current `start.pm` doesn't touch workers.

- [ ] **Step 3: Refactor `_start_one` to return a "running" flag, then cascade**

Replace `lib/Deploy/Command/start.pm` with:

```perl
package Deploy::Command::start;

use Mojo::Base 'Deploy::Command', -signatures;

has description => 'Start a service';
has usage => sub ($self) { $self->extract_usage };

sub run ($self, @args) {
    my ($svc_input, $target) = $self->parse_target(@args);
    die $self->usage unless $svc_input;
    my @names = $self->resolve_service($svc_input);
    $self->config->target($target);

    for my $name (@names) {
        my $transport = $self->transport_for($name, $target);
        my $up = $self->_start_one($name, $target, $transport);

        # Cascade worker starts only when the main service ended up running.
        # No-op when $name is a worker or has no workers.
        if ($up) {
            for my $w (@{ $self->config->workers_of($name) }) {
                $self->_start_one($w, $target, $transport);
            }
        }
    }

    $self->_show_status($svc_input, $target);
}

sub _show_status ($self, $svc_input, $target) {
    say "";
    require Deploy::Command::status;
    Deploy::Command::status->new(app => $self->app)->run($svc_input, $target);
}

# Start one service. Returns 1 if the service ended up running (already
# running OR a fresh start succeeded and the port responded). Returns 0
# otherwise. Also handles workers: they have no port, so port_ok is
# auto-true for them (`check_port` returns 0 for an undef port).
sub _start_one ($self, $name, $target, $transport) {
    $transport //= $self->transport_for($name, $target);
    $self->ensure_fresh_ubic($name, $transport);
    my $svc  = $self->config->service($name);
    my $port = $svc->{port} // '?';
    my $url  = $self->service_url($svc);

    my $status = $transport->run("ubic status $name 2>&1");
    if ($status->{ok} && $status->{output} =~ /running \(pid (\d+)\)/) {
        say "  \e[32m$name is already running\e[0m  pid:$1  port:$port  $url";
        return 1;
    }

    if ($port && $port ne '?' && $self->check_port($port, $transport)) {
        my $who = $transport->run("ss -tlnp | grep ':$port '");
        say "  \e[31m$name: port $port is already in use\e[0m";
        say "  $who->{output}" if $who->{output} && $who->{output} =~ /\S/;
        return 0;
    }

    my $r = $transport->run("ubic start $name");

    if ($r->{output} && $r->{output} =~ /not found|unknown service/i) {
        say "  \e[31m$name is not installed\e[0m — run: 321 install $name" . $self->target_flag($target);
        return 0;
    }

    say "  $r->{output}" if $r->{output} && $r->{output} =~ /\S/;

    sleep 2;
    # Workers have no port; treat them as up if ubic reports running.
    my $port_ok = ($svc->{is_worker} || !$port || $port eq '?')
        ? 1
        : $self->check_port($port, $transport);

    if ($port_ok) {
        say "  \e[32m$name running\e[0m ($target)" . ($port ne '?' ? "  port:$port" : '') . "  $url";
        return 1;
    } else {
        say "  \e[31m$name not running\e[0m after start";
        $self->print_failure($transport, $name, $target);
        return 0;
    }
}

1;

=head1 SYNOPSIS

  Usage: APPLICATION start <service>

  Starts the named service. When the name is a main with workers
  declared in 321.yml, every worker is started after the main comes
  up. Naming a worker directly starts only that worker.

=cut
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `prove -lv t/40-worker-cascade.t`
Expected: all subtests pass.

- [ ] **Step 5: Run the full suite**

Run: `prove -lr t`
Expected: all tests pass.

- [ ] **Step 6: Commit and push**

```bash
git add lib/Deploy/Command/start.pm t/40-worker-cascade.t
git commit -m "$(cat <<'EOF'
start: cascade worker starts after main comes up

'321 start <main>' now starts each worker (sorted order) once the
main service is confirmed running. Workers reuse the same _start_one
path so port checks, "already running", and "not installed" detection
all just work — with port_ok auto-true for workers (they have no
port).

_start_one now returns a boolean so the cascade can be gated on
the main coming up.
EOF
)"
git push
```

---

## Task 6: `321 go` cascades worker restarts after main redeploy

Go has two branches: install (first-time bring-up) and redeploy (hot-restart). Per the spec, the cascade lives on the redeploy branch only — the install branch already brings the whole unit up via `321 generate` + initial start.

**Files:**
- Modify: `lib/Deploy/Command/go.pm`
- Modify: `t/40-worker-cascade.t`

- [ ] **Step 1: Add the failing test**

Append to `t/40-worker-cascade.t` before `done_testing`:

```perl
# Stubbed go subclass: swap transport, stub svc_mgr->deploy, skip the
# nginx/host fixup, skip the install path.
package StubSvcMgrDeploy {
    sub new { bless { result => $_[1] }, $_[0] }
    sub transport { }
    sub deploy { $_[0]->{result} }
}

package TestGo {
    use parent -norequire, 'Deploy::Command::go';
    our ($TRANSPORT, $SVC_MGR);
    # Force the redeploy branch by reporting "OK" for the install probe.
    sub transport_for {
        my ($self, $name, $target) = @_;
        # Wrap so the very first run() (the OK probe) reports OK, and
        # subsequent runs hit the RecordingTransport for assertion.
        return TestGoTransport->new($TRANSPORT);
    }
    sub svc_mgr        { $SVC_MGR }
    sub _ensure_serving { }       # skip nginx/hosts side trips
}

# Wraps a RecordingTransport so the *first* call (the install probe in
# go.pm) returns 'OK' without being recorded, and every subsequent call
# is delegated to the underlying recorder.
package TestGoTransport {
    sub new {
        my ($class, $inner) = @_;
        return bless { inner => $inner, first => 1 }, $class;
    }
    sub run {
        my ($self, $cmd, %opts) = @_;
        if ($self->{first}) {
            $self->{first} = 0;
            return { ok => 1, output => "OK\n" };   # install probe passes
        }
        return $self->{inner}->run($cmd, %opts);
    }
    sub isa { 0 }
}

subtest 'go demo.web cascades to workers after redeploy success' => sub {
    my ($home, $scan, $scan_obj, $home_obj) = make_fixture();
    my $cfg = Deploy::Config->new(app_home => $home, scan_dir => $scan, target => 'live');
    my $recorder = RecordingTransport->new;
    local $TestGo::TRANSPORT = $recorder;
    local $TestGo::SVC_MGR = StubSvcMgrDeploy->new({
        status => 'success',
        message => 'deployed',
        data => { steps => [] },
    });
    my $cmd = TestGo->new(app => make_app($cfg));
    $cmd->run('demo.web', 'live');
    is_deeply [$recorder->calls],
        ['ubic restart demo.mailer', 'ubic restart demo.printer'],
        'workers restart after main, sorted order';
};

subtest 'go demo.web does NOT cascade when main deploy errors' => sub {
    my ($home, $scan, $scan_obj, $home_obj) = make_fixture();
    my $cfg = Deploy::Config->new(app_home => $home, scan_dir => $scan, target => 'live');
    my $recorder = RecordingTransport->new;
    local $TestGo::TRANSPORT = $recorder;
    local $TestGo::SVC_MGR = StubSvcMgrDeploy->new({
        status => 'error',
        message => 'deploy failed',
        data => { steps => [] },
    });
    my $cmd = TestGo->new(app => make_app($cfg));
    $cmd->run('demo.web', 'live');
    is_deeply [$recorder->calls], [], 'cascade skipped on deploy error';
};

subtest 'go demo.printer (worker target) does not cascade' => sub {
    my ($home, $scan, $scan_obj, $home_obj) = make_fixture();
    my $cfg = Deploy::Config->new(app_home => $home, scan_dir => $scan, target => 'live');
    my $recorder = RecordingTransport->new;
    local $TestGo::TRANSPORT = $recorder;
    local $TestGo::SVC_MGR = StubSvcMgrDeploy->new({
        status => 'success',
        message => 'deployed',
        data => { steps => [] },
    });
    my $cmd = TestGo->new(app => make_app($cfg));
    $cmd->run('demo.printer', 'live');
    is_deeply [$recorder->calls], [], 'no cascade when target is a worker';
};
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `prove -lv t/40-worker-cascade.t`
Expected: the new subtests fail — current `go.pm` doesn't touch workers after redeploy.

- [ ] **Step 3: Edit `go.pm` to cascade after redeploy**

In `lib/Deploy/Command/go.pm`, find the redeploy branch at the end of `run` (lines 56-66):

```perl
    my $svc_mgr = $self->svc_mgr;
    $svc_mgr->transport($transport);

    say "3... 2... 1... deploying $name ($target)";
    my $skip_git = ($target eq 'dev') ? 1 : 0;
    my $r = $svc_mgr->deploy($name, skip_git => $skip_git);
    $self->print_steps($r);
    say "  $r->{message}" if $r->{message};

    $self->_ensure_serving($name, $target, $transport);
}
```

Replace with:

```perl
    my $svc_mgr = $self->svc_mgr;
    $svc_mgr->transport($transport);

    say "3... 2... 1... deploying $name ($target)";
    my $skip_git = ($target eq 'dev') ? 1 : 0;
    my $r = $svc_mgr->deploy($name, skip_git => $skip_git);
    $self->print_steps($r);
    say "  $r->{message}" if $r->{message};

    $self->_ensure_serving($name, $target, $transport);

    # Workers share the repo we just deployed; just bounce them so they
    # pick up new code. Gate on main deploy success — no point bouncing
    # workers if the main step bailed.
    if (($r->{status} // '') ne 'error') {
        for my $row (@{ $self->cascade_workers($name, 'restart', $transport) }) {
            $self->print_worker_step('restart', $row);
        }
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `prove -lv t/40-worker-cascade.t`
Expected: all subtests pass.

- [ ] **Step 5: Run the full suite**

Run: `prove -lr t`
Expected: all tests pass.

- [ ] **Step 6: Commit and push**

```bash
git add lib/Deploy/Command/go.pm t/40-worker-cascade.t
git commit -m "$(cat <<'EOF'
go: cascade worker restarts after main redeploy

'321 go <main>' now restarts every worker (sorted order) after the
main redeploy reports something other than error. Workers share the
repo the main just deployed, so a plain 'ubic restart' is enough to
pick up new code. The install branch is unchanged — the initial
'321 install' brings every worker's ubic file into place via
'321 generate', so they will start under the redeploy path on the
next 'go'.
EOF
)"
git push
```

---

## Task 7: Docs update — CLAUDE.md, AGENT.md, using-321 skill

Tell the next operator (and the next agent) about the cascade.

**Files:**
- Modify: `CLAUDE.md`
- Modify: `AGENT.md`
- Modify: `/home/nige/.claude/skills/using-321/SKILL.md`

- [ ] **Step 1: Update `CLAUDE.md` — add a section under "Service naming"**

In `/home/s3/web.321.do/CLAUDE.md`, find the "Service naming" section:

```markdown
### Service naming

Service names are `<group>.<name>` (e.g. `321.web`, `123.api`). The group/name split drives the ubic symlink layout: `~/ubic/service/<group>/<name>` → `<repo>/ubic/service/<group>/<name>`.
```

Append immediately after that paragraph:

```markdown
### Workers and the lifecycle cascade

Services declared under a parent's `workers:` block in `321.yml` are expanded into independent ubic services named `<group>.<workerName>` (a minion worker on `123.api` becomes the ubic service `123.minion`). They share the parent's repo, perl version, and target config, but they have their own pid, logs, and ubic file.

`321 go`, `321 start`, `321 stop`, and `321 restart` treat the parent and its workers as one unit when the *parent* is named. The parent runs first on start/go/restart; workers are restarted after in sorted name order. Stop iterates in reverse — workers first, parent last — so jobs settle before the connection they depend on goes away. Naming a worker directly (`321 restart 123.minion`) acts only on that worker, so a stuck worker can be cycled without disturbing the web tier.

Per-worker failures are reported but don't abort the cascade or the main step. A failed main step skips the worker pass — there is nothing useful to cascade to.
```

- [ ] **Step 2: Update `AGENT.md` — add the same essentials**

In `/home/s3/web.321.do/AGENT.md`, find the "Common gotchas" heading. Immediately before it, insert:

```markdown
## Workers and the lifecycle cascade

`workers:` entries in a service's `321.yml` become independent ubic services named `<group>.<workerName>`. The lifecycle commands treat parent + workers as one unit when the parent is named:

- `321 go <parent>`  — main redeploy, then `ubic restart` each worker (sorted)
- `321 start <parent>`  — main start, then start each worker (sorted)
- `321 restart <parent>`  — main restart, then `ubic restart` each worker
- `321 stop <parent>`  — stop workers in reverse sorted order, then stop main

Naming a worker directly (`321 restart 123.minion`) only touches that worker — the escape hatch when a single worker needs cycling.

Failed worker steps are reported but don't abort the cascade or the main step. A failed main step skips the worker pass.

```

- [ ] **Step 3: Update the using-321 skill**

In `/home/nige/.claude/skills/using-321/SKILL.md`, find the "Quick decision table" section. After the last row of the table (the one about `321 restart <name>` regenerating the ubic file), add four new rows before the section ends:

```markdown
| "Restart this service AND its minion/workers" | `321 restart <parent>` — cascades to workers in sorted name order |
| "Cycle just one stuck worker" | `321 restart <parent>.<workerName>` — naming a worker directly skips the cascade |
| "Bring the whole unit (web + workers) up/down" | `321 start <parent>` / `321 stop <parent>` — start cascades sorted, stop in reverse |
| "Deploy and want workers on new code too" | `321 go <parent>` — main redeploys, workers bounced via `ubic restart` after |
```

Then find the "Hard rules — don't bypass" section. After the bullet that says "Don't hand-roll `git pull && cpanm && ubic restart`...", append a new bullet:

```markdown
- **Workers are part of the unit**: when a service has a `workers:` block (e.g. a minion worker), `321 <go|start|stop|restart> <parent>` cascades to every worker. Don't run `321 restart parent` then `ubic restart parent.worker` by hand — the cascade already did it. Name the worker directly only when you want it isolated.
```

- [ ] **Step 4: Commit and push the doc changes**

```bash
git add CLAUDE.md AGENT.md
git commit -m "$(cat <<'EOF'
Document the worker lifecycle cascade

go/start/stop/restart now treat a service + its workers as one unit
when the main service is named. Worker name escapes the cascade and
acts on just that worker.
EOF
)"
git push
```

The `using-321` skill lives outside the repo (`/home/nige/.claude/skills/using-321/SKILL.md`); no git commit needed for it.

---

## Manual verification (optional but recommended)

After all tasks complete, on a service that actually has a worker:

```bash
# 123.api has 123.minion as a worker
321 status 123.api
321 status 123.minion

# Cycle the whole unit
321 restart 123.api
# Expect:
#   [OK] worker 123.minion restarted   ← cascade fired

# Cycle just the worker — no cascade
321 restart 123.minion
# Expect: only 123.minion lines
```

If you don't have a service-with-worker in your environment, every behaviour is covered by the test file — `prove -lv t/40-worker-cascade.t` is the regression net.

---

## Self-review notes

- **Spec coverage:** Tasks 1-6 implement every bullet in the Behavior table; Task 7 covers the docs. Failure handling, ordering, sorted-vs-reverse-sorted, and worker-only target behavior are each exercised by named subtests.
- **Test count:** ~16 subtests across 6 tasks, all in one file (`t/40-worker-cascade.t`). The same fixture helper is reused across tasks.
- **No production calls in tests** — every external command is intercepted by `RecordingTransport`. Tests run with no ubic on the machine.
- **Existing test impact:** `t/27-service-lifecycle.t` and other fixture tests use manifests without `workers:`, so `workers_of` returns `[]` and the cascade is a no-op for them — no expected regressions. Step 5 of Tasks 1, 3, and 5 runs `prove -lr t` to catch any surprises.
