# CLI-First SSH-Driven 321 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor 321 from a deployed web service into a local-only CLI + dashboard that drives remote servers via SSH, eliminating the production security surface and enabling multi-server support.

**Architecture:** A new `Deploy::Transport` abstraction sits between all manager modules (Service, Ubic, Nginx, Logs) and the OS. It dispatches commands either locally (`Deploy::Local`) or over SSH (`Deploy::SSH`) based on whether the resolved target has `ssh` config. All existing managers gain a `transport` attribute and route their shell calls through it. The CLI passes target as the last argument; the dashboard uses a target dropdown. Manifest renamed from `.321.yml` to `321.yml`.

**Tech Stack:** Perl 5.42, Mojolicious::Lite, Mojolicious::Commands, YAML::XS, Path::Tiny, Ubic, OpenSSH (system `ssh`/`scp` binaries). No new CPAN dependencies.

---

## File Structure

**New files:**
- `lib/Deploy/Transport.pm` — factory: returns Local or SSH transport based on target config
- `lib/Deploy/Local.pm` — local command execution (wraps current backtick pattern)
- `lib/Deploy/SSH.pm` — remote command execution via system `ssh`/`scp`
- `lib/Deploy/Command/dash.pm` — `321 dash` subcommand (renamed from `daemon`)
- `lib/Deploy/Command/logs.pm` — `321 logs` subcommand with tail/search/analyse
- `lib/Deploy/Command/rebuild.pm` — `321 rebuild` (renamed from `generate`)
- `t/30-local-transport.t` — Local transport tests
- `t/31-ssh-transport.t` — SSH transport tests (mocked)
- `t/32-transport-factory.t` — Transport factory tests
- `t/33-config-ssh-targets.t` — Config with SSH target resolution
- `t/34-service-with-transport.t` — Service operations through transport

**Modified files:**
- `lib/Deploy/Config.pm` — SSH fields in target resolution, `321.yml` manifest (not `.321.yml`), target from CLI arg not cookie
- `lib/Deploy/Service.pm` — replace `_run_in_dir`/`_run_cmd`/`_check_port` with transport calls
- `lib/Deploy/Ubic.pm` — use transport for symlink installation on remote targets
- `lib/Deploy/Nginx.pm` — use transport for `nginx -t`, `systemctl reload`, config file writes
- `lib/Deploy/Logs.pm` — use transport for remote log reading
- `lib/Deploy/Manifest.pm` — load `321.yml` instead of `.321.yml`
- `lib/Deploy/Command.pm` — add target resolution from CLI args
- `lib/Deploy/Command/install.pm` — full remote bootstrap via transport
- `lib/Deploy/Command/go.pm` — pass target through
- `lib/Deploy/Command/start.pm` — pass target through
- `lib/Deploy/Command/stop.pm` — pass target through
- `lib/Deploy/Command/restart.pm` — pass target through
- `lib/Deploy/Command/update.pm` — pass target through
- `lib/Deploy/Command/migrate.pm` — pass target through
- `lib/Deploy/Command/status.pm` — pass target through
- `lib/Deploy/Command/list.pm` — pass target through
- `bin/321.pl` — strip auth, strip JSON API routes, simplify dashboard, add target dropdown

**Deleted files:**
- `lib/Deploy/Secrets.pm` — web UI for secrets removed (env files managed manually)
- `lib/Deploy/Command/generate.pm` — replaced by `rebuild.pm`
- `bin/install.pl` — replaced by `321 install <service> <target>`
- `.321.yml` — renamed to `321.yml`

**Untouched:**
- `lib/Deploy/CertProvider.pm` — already returns commands as strings; transport runs them
- `lib/Deploy/Hosts.pm` — local-only, no transport needed

---

## Task 1: Deploy::Local — extract current execution pattern

Extract the existing backtick execution pattern from `Deploy::Service` into a standalone module. No behaviour change — just moving code.

**Files:**
- Create: `lib/Deploy/Local.pm`
- Create: `t/30-local-transport.t`

- [ ] **Step 1: Write failing tests**

Create `t/30-local-transport.t`:

```perl
use strict;
use warnings;
use Test::More;
use Deploy::Local;

my $t = Deploy::Local->new;

subtest 'run: simple command' => sub {
    my $r = $t->run('echo hello');
    ok $r->{ok}, 'exit 0 is ok';
    like $r->{output}, qr/hello/, 'captures stdout';
};

subtest 'run: failing command' => sub {
    my $r = $t->run('false');
    ok !$r->{ok}, 'non-zero exit is not ok';
};

subtest 'run: command with timeout' => sub {
    my $r = $t->run('sleep 10', timeout => 1);
    ok !$r->{ok}, 'timed out command is not ok';
    like $r->{output}, qr/timed out/i, 'output mentions timeout';
};

subtest 'run_in_dir: runs in specified directory' => sub {
    my $r = $t->run_in_dir('/tmp', 'pwd');
    ok $r->{ok};
    like $r->{output}, qr{/tmp}, 'ran in /tmp';
};

subtest 'run_steps: aborts on failure' => sub {
    my @results;
    my $r = $t->run_steps([
        { cmd => 'echo step1', label => 'first' },
        { cmd => 'false',      label => 'fail' },
        { cmd => 'echo step3', label => 'never' },
    ]);
    is scalar @{ $r->{steps} }, 2, 'stopped after failure';
    ok $r->{steps}[0]{ok}, 'step 1 passed';
    ok !$r->{steps}[1]{ok}, 'step 2 failed';
};

subtest 'upload: copies file' => sub {
    use Path::Tiny qw(tempdir path);
    my $src = tempdir(CLEANUP => 1);
    my $dst = tempdir(CLEANUP => 1);
    path($src, 'test.txt')->spew_utf8("hello\n");
    my $r = $t->upload("$src/test.txt", "$dst/test.txt");
    ok $r->{ok}, 'upload succeeded';
    is path($dst, 'test.txt')->slurp_utf8, "hello\n", 'file copied';
};

done_testing;
```

- [ ] **Step 2: Run tests — all should fail**

Run: `prove -lv t/30-local-transport.t`
Expected: FAIL with "Can't locate Deploy/Local.pm".

- [ ] **Step 3: Implement Deploy::Local**

Create `lib/Deploy/Local.pm`:

```perl
package Deploy::Local;

use Mojo::Base -base, -signatures;

has 'perlbrew';

sub run ($self, $cmd, %opts) {
    my $timeout = $opts{timeout} // 120;
    my $full_cmd = $self->_wrap_cmd($cmd);

    my $output = eval {
        local $SIG{ALRM} = sub { die "Command timed out\n" };
        alarm $timeout;
        my $result = `$full_cmd 2>&1`;
        alarm 0;
        $result;
    };
    alarm 0;

    if ($@) {
        return { ok => 0, output => "Error: $@", exit_code => -1 };
    }
    return { ok => ($? == 0), output => ($output // ''), exit_code => $? >> 8 };
}

sub run_in_dir ($self, $dir, $cmd, %opts) {
    return $self->run("cd \Q$dir\E && $cmd", %opts);
}

sub run_steps ($self, $steps, %opts) {
    my @results;
    for my $step (@$steps) {
        my $r = $self->run($step->{cmd}, %opts);
        $r->{label} = $step->{label};
        push @results, $r;
        unless ($r->{ok}) {
            return { ok => 0, steps => \@results };
        }
    }
    return { ok => 1, steps => \@results };
}

sub stream ($self, $cmd, %opts) {
    my $full_cmd = $self->_wrap_cmd($cmd);
    open my $fh, '-|', "bash -c '$full_cmd'" or return { ok => 0, output => "Failed to open: $!" };
    my $cb = $opts{on_line};
    while (my $line = <$fh>) {
        if ($cb) {
            $cb->($line);
        } else {
            print $line;
        }
    }
    close $fh;
    return { ok => ($? == 0) };
}

sub upload ($self, $local, $remote) {
    require File::Copy;
    my $ok = File::Copy::copy($local, $remote);
    return { ok => $ok ? 1 : 0, output => $ok ? "Copied $local -> $remote" : "Copy failed: $!" };
}

sub _wrap_cmd ($self, $cmd) {
    my $pb = $self->perlbrew;
    return $cmd unless $pb;
    return "bash -lc 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use $pb && $cmd'";
}

1;
```

- [ ] **Step 4: Run tests — all should pass**

Run: `prove -lv t/30-local-transport.t`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/Deploy/Local.pm t/30-local-transport.t
git commit -m "Add Deploy::Local transport for local command execution"
```

---

## Task 2: Deploy::SSH — remote command execution

**Files:**
- Create: `lib/Deploy/SSH.pm`
- Create: `t/31-ssh-transport.t`

- [ ] **Step 1: Write failing tests**

Create `t/31-ssh-transport.t`. We test command building and parsing without a real SSH server:

```perl
use strict;
use warnings;
use Test::More;
use Deploy::SSH;

my $ssh = Deploy::SSH->new(
    user     => 'ubuntu',
    host     => 'example.com',
    key      => '/tmp/fake.pem',
    perlbrew => 'perl-5.42.0',
);

subtest 'builds correct ssh command' => sub {
    my $cmd = $ssh->_ssh_cmd('echo hello');
    like $cmd, qr/ssh\s/, 'starts with ssh';
    like $cmd, qr/-i \/tmp\/fake\.pem/, 'includes key';
    like $cmd, qr/ubuntu\@example\.com/, 'includes user@host';
    like $cmd, qr/perlbrew use perl-5\.42\.0/, 'wraps with perlbrew';
    like $cmd, qr/echo hello/, 'includes the actual command';
};

subtest 'ssh command without perlbrew' => sub {
    my $ssh_nopb = Deploy::SSH->new(
        user => 'ubuntu',
        host => 'example.com',
        key  => '/tmp/fake.pem',
    );
    my $cmd = $ssh_nopb->_ssh_cmd('whoami');
    unlike $cmd, qr/perlbrew/, 'no perlbrew wrapping';
    like $cmd, qr/whoami/, 'includes command';
};

subtest 'builds correct scp command' => sub {
    my $cmd = $ssh->_scp_cmd('/local/file.txt', '/remote/file.txt');
    like $cmd, qr/scp\s/, 'starts with scp';
    like $cmd, qr/-i \/tmp\/fake\.pem/, 'includes key';
    like $cmd, qr{ubuntu\@example\.com:/remote/file\.txt}, 'includes remote path';
    like $cmd, qr{/local/file\.txt}, 'includes local path';
};

subtest 'run_in_dir wraps with cd' => sub {
    my $cmd = $ssh->_ssh_cmd_in_dir('/home/s3/app', 'cpanm --installdeps .');
    like $cmd, qr{cd /home/s3/app && cpanm --installdeps \.}, 'cd prepended';
};

done_testing;
```

- [ ] **Step 2: Run tests — all should fail**

Run: `prove -lv t/31-ssh-transport.t`
Expected: FAIL with "Can't locate Deploy/SSH.pm".

- [ ] **Step 3: Implement Deploy::SSH**

Create `lib/Deploy/SSH.pm`:

```perl
package Deploy::SSH;

use Mojo::Base -base, -signatures;

has 'user';
has 'host';
has 'key';
has 'perlbrew';

sub _ssh_base ($self) {
    my @parts = ('ssh', '-o', 'StrictHostKeyChecking=accept-new', '-T');
    push @parts, '-i', $self->key if $self->key;
    push @parts, $self->user . '@' . $self->host;
    return join(' ', @parts);
}

sub _wrap_perlbrew ($self, $cmd) {
    my $pb = $self->perlbrew;
    return $cmd unless $pb;
    return "source ~/perl5/perlbrew/etc/bashrc && perlbrew use $pb && $cmd";
}

sub _ssh_cmd ($self, $cmd) {
    my $wrapped = $self->_wrap_perlbrew($cmd);
    return $self->_ssh_base . " '" . $self->_shell_escape($wrapped) . "'";
}

sub _ssh_cmd_in_dir ($self, $dir, $cmd) {
    return $self->_ssh_cmd("cd $dir && $cmd");
}

sub _scp_cmd ($self, $local, $remote) {
    my @parts = ('scp');
    push @parts, '-i', $self->key if $self->key;
    push @parts, $local, $self->user . '@' . $self->host . ':' . $remote;
    return join(' ', @parts);
}

sub run ($self, $cmd, %opts) {
    my $timeout = $opts{timeout} // 120;
    my $full_cmd = $self->_ssh_cmd($cmd);

    my $output = eval {
        local $SIG{ALRM} = sub { die "Command timed out\n" };
        alarm $timeout;
        my $result = `$full_cmd 2>&1`;
        alarm 0;
        $result;
    };
    alarm 0;

    if ($@) {
        return { ok => 0, output => "Error: $@", exit_code => -1 };
    }
    return { ok => ($? == 0), output => ($output // ''), exit_code => $? >> 8 };
}

sub run_in_dir ($self, $dir, $cmd, %opts) {
    my $timeout = $opts{timeout} // 120;
    my $full_cmd = $self->_ssh_cmd_in_dir($dir, $cmd);

    my $output = eval {
        local $SIG{ALRM} = sub { die "Command timed out\n" };
        alarm $timeout;
        my $result = `$full_cmd 2>&1`;
        alarm 0;
        $result;
    };
    alarm 0;

    if ($@) {
        return { ok => 0, output => "Error: $@", exit_code => -1 };
    }
    return { ok => ($? == 0), output => ($output // ''), exit_code => $? >> 8 };
}

sub run_steps ($self, $steps, %opts) {
    my @results;
    for my $step (@$steps) {
        my $r = $self->run($step->{cmd}, %opts);
        $r->{label} = $step->{label};
        push @results, $r;
        unless ($r->{ok}) {
            return { ok => 0, steps => \@results };
        }
    }
    return { ok => 1, steps => \@results };
}

sub stream ($self, $cmd, %opts) {
    my $full_cmd = $self->_ssh_cmd($cmd);
    open my $fh, '-|', $full_cmd or return { ok => 0, output => "Failed to open: $!" };
    my $cb = $opts{on_line};
    while (my $line = <$fh>) {
        if ($cb) {
            $cb->($line);
        } else {
            print $line;
        }
    }
    close $fh;
    return { ok => ($? == 0) };
}

sub upload ($self, $local, $remote) {
    my $cmd = $self->_scp_cmd($local, $remote);
    my $output = `$cmd 2>&1`;
    return { ok => ($? == 0), output => $output };
}

sub _shell_escape ($self, $str) {
    $str =~ s/'/'\\''/g;
    return $str;
}

1;
```

- [ ] **Step 4: Run tests — all should pass**

Run: `prove -lv t/31-ssh-transport.t`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/Deploy/SSH.pm t/31-ssh-transport.t
git commit -m "Add Deploy::SSH transport for remote command execution"
```

---

## Task 3: Deploy::Transport — factory that picks Local or SSH

**Files:**
- Create: `lib/Deploy/Transport.pm`
- Create: `t/32-transport-factory.t`

- [ ] **Step 1: Write failing tests**

Create `t/32-transport-factory.t`:

```perl
use strict;
use warnings;
use Test::More;
use Deploy::Transport;

subtest 'local target returns Deploy::Local' => sub {
    my $t = Deploy::Transport->for_target({
        host => 'love.do.dev',
        port => 8888,
        runner => 'morbo',
    });
    isa_ok $t, 'Deploy::Local';
};

subtest 'ssh target returns Deploy::SSH' => sub {
    my $t = Deploy::Transport->for_target({
        ssh     => 'ubuntu@example.com',
        ssh_key => '~/.ssh/test.pem',
        host    => 'love.do',
        port    => 8888,
        runner  => 'hypnotoad',
    });
    isa_ok $t, 'Deploy::SSH';
    is $t->user, 'ubuntu', 'parsed user';
    is $t->host, 'example.com', 'parsed host';
    is $t->key, '~/.ssh/test.pem', 'set key';
};

subtest 'ssh target with perlbrew' => sub {
    my $t = Deploy::Transport->for_target({
        ssh      => 'ubuntu@example.com',
        ssh_key  => '~/.ssh/test.pem',
        host     => 'love.do',
        port     => 8888,
    }, perlbrew => 'perl-5.42.0');
    isa_ok $t, 'Deploy::SSH';
    is $t->perlbrew, 'perl-5.42.0', 'perlbrew passed through';
};

subtest 'local target with perlbrew' => sub {
    my $t = Deploy::Transport->for_target({
        host => 'love.do.dev',
        port => 8888,
    }, perlbrew => 'perl-5.42.0');
    isa_ok $t, 'Deploy::Local';
    is $t->perlbrew, 'perl-5.42.0', 'perlbrew passed through';
};

done_testing;
```

- [ ] **Step 2: Run tests — all should fail**

Run: `prove -lv t/32-transport-factory.t`
Expected: FAIL with "Can't locate Deploy/Transport.pm".

- [ ] **Step 3: Implement Deploy::Transport**

Create `lib/Deploy/Transport.pm`:

```perl
package Deploy::Transport;

use Mojo::Base -strict, -signatures;
use Deploy::Local;
use Deploy::SSH;

sub for_target ($class, $target, %opts) {
    if ($target->{ssh}) {
        my ($user, $host) = split /\@/, $target->{ssh}, 2;
        return Deploy::SSH->new(
            user     => $user,
            host     => $host,
            key      => $target->{ssh_key},
            ($opts{perlbrew} ? (perlbrew => $opts{perlbrew}) : ()),
        );
    }

    return Deploy::Local->new(
        ($opts{perlbrew} ? (perlbrew => $opts{perlbrew}) : ()),
    );
}

1;
```

- [ ] **Step 4: Run tests — all should pass**

Run: `prove -lv t/32-transport-factory.t`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/Deploy/Transport.pm t/32-transport-factory.t
git commit -m "Add Deploy::Transport factory: Local or SSH based on target config"
```

---

## Task 4: Config — SSH targets, CLI target arg, 321.yml rename

Extend `Deploy::Config` to include SSH fields in resolved targets, accept target as a parameter (not cookie), and load `321.yml` instead of `.321.yml`.

**Files:**
- Modify: `lib/Deploy/Config.pm`
- Modify: `lib/Deploy/Manifest.pm`
- Rename: `.321.yml` → `321.yml`
- Create: `t/33-config-ssh-targets.t`

- [ ] **Step 1: Write failing tests**

Create `t/33-config-ssh-targets.t`:

```perl
use strict;
use warnings;
use Test::More;
use Path::Tiny qw(tempdir path);
use Deploy::Config;

my $home = tempdir(CLEANUP => 1);
path($home, 'services')->mkpath;
path($home, 'secrets')->mkpath;

my $repo = tempdir(CLEANUP => 1);
path($repo, '321.yml')->spew_utf8(<<'YAML');
name: demo.web
entry: bin/app.pl
runner: hypnotoad
perl: perl-5.42.0
YAML

path($home, 'services', 'demo.web.yml')->spew_utf8(<<"YAML");
name: demo.web
repo: $repo
branch: main
targets:
  dev:
    host: demo.do.dev
    port: 9400
    runner: morbo
  live:
    ssh: ubuntu\@ec2-example.compute.amazonaws.com
    ssh_key: ~/.ssh/kaizen.pem
    host: demo.do
    port: 9400
    runner: hypnotoad
YAML

subtest 'dev target has no ssh fields' => sub {
    my $c = Deploy::Config->new(app_home => $home, target => 'dev');
    my $svc = $c->service('demo.web');
    ok !$svc->{ssh}, 'no ssh on dev';
    ok !$svc->{ssh_key}, 'no ssh_key on dev';
    is $svc->{host}, 'demo.do.dev';
    is $svc->{runner}, 'morbo';
};

subtest 'live target has ssh fields' => sub {
    my $c = Deploy::Config->new(app_home => $home, target => 'live');
    my $svc = $c->service('demo.web');
    is $svc->{ssh}, 'ubuntu@ec2-example.compute.amazonaws.com', 'ssh parsed';
    is $svc->{ssh_key}, '~/.ssh/kaizen.pem', 'ssh_key parsed';
    is $svc->{host}, 'demo.do';
    is $svc->{runner}, 'hypnotoad';
};

subtest 'manifest loaded from 321.yml (not .321.yml)' => sub {
    my $c = Deploy::Config->new(app_home => $home, target => 'live');
    my $svc = $c->service('demo.web');
    is $svc->{bin}, 'bin/app.pl', 'entry from manifest';
    is $svc->{perlbrew}, 'perl-5.42.0', 'perl from manifest';
};

subtest 'manifest not found with .321.yml' => sub {
    # Rename to .321.yml — should not be found
    path($repo, '321.yml')->move(path($repo, '.321.yml'));
    my $c = Deploy::Config->new(app_home => $home, target => 'live');
    my $svc = $c->service('demo.web');
    ok !$svc->{bin}, 'no bin when only .321.yml exists';
    # Restore
    path($repo, '.321.yml')->move(path($repo, '321.yml'));
};

done_testing;
```

- [ ] **Step 2: Run tests — should fail**

Run: `prove -lv t/33-config-ssh-targets.t`
Expected: FAIL — ssh/ssh_key not in resolved output, Manifest still loads `.321.yml`.

- [ ] **Step 3: Update Deploy::Manifest to load `321.yml`**

In `lib/Deploy/Manifest.pm`, change line 11:

```perl
# Old:
my $file = path($repo_dir, '.321.yml');

# New:
my $file = path($repo_dir, '321.yml');
```

- [ ] **Step 4: Update Deploy::Config::_resolve to pass through SSH fields**

In `lib/Deploy/Config.pm`, replace `_resolve` (lines 94-115) with:

```perl
sub _resolve ($self, $name, $raw) {
    my $target_name = $self->target;
    my $targets = $raw->{targets} // {};
    my $target  = $targets->{$target_name} // $targets->{live} // {};

    my $manifest = $raw->{repo} && -d $raw->{repo}
        ? Deploy::Manifest->load($raw->{repo})
        : undef;

    my $bin      = $raw->{bin}      // ($manifest ? $manifest->{entry}  : undef);
    my $perlbrew = $raw->{perlbrew} // ($manifest ? $manifest->{perl}   : undef);
    my $runner   = $target->{runner} // ($manifest ? $manifest->{runner} : 'hypnotoad');

    return {
        name     => $name,
        repo     => $raw->{repo},
        branch   => $raw->{branch} // 'master',
        bin      => $bin,
        mode     => $runner eq 'morbo' ? 'development' : 'production',
        runner   => $runner,
        port     => $target->{port},
        logs     => $target->{logs} // {},
        env      => $target->{env} // {},
        host     => $target->{host} // 'localhost',
        apt_deps => $raw->{apt_deps} // [],
        health       => $manifest ? $manifest->{health} : '/health',
        env_required => $manifest ? $manifest->{env_required} : {},
        env_optional => $manifest ? $manifest->{env_optional} : {},
        ($target->{ssh}     ? (ssh     => $target->{ssh})     : ()),
        ($target->{ssh_key} ? (ssh_key => $target->{ssh_key}) : ()),
        ($target->{docs}    ? (docs    => $target->{docs})    : ()),
        ($target->{admin}   ? (admin   => $target->{admin})   : ()),
        ($perlbrew           ? (perlbrew => $perlbrew)         : ()),
    };
}
```

Add at the top of `lib/Deploy/Config.pm`, after the existing `use` lines:

```perl
use Deploy::Manifest;
```

- [ ] **Step 5: Rename `.321.yml` to `321.yml`**

```bash
git mv .321.yml 321.yml
```

- [ ] **Step 6: Run tests — all should pass**

Run: `prove -lv t/33-config-ssh-targets.t`
Expected: PASS.

- [ ] **Step 7: Run full suite — check for regressions**

Run: `prove -lr t`
Expected: Some tests may fail if they reference `.321.yml` — fix any manifest test fixtures that use the old name.

- [ ] **Step 8: Fix t/10-manifest.t fixture paths**

In `t/10-manifest.t`, replace all instances of `.321.yml` with `321.yml`:

```perl
# Old:
path($dir, '.321.yml')->spew_utf8(...);

# New:
path($dir, '321.yml')->spew_utf8(...);
```

- [ ] **Step 9: Run full suite — confirm clean**

Run: `prove -lr t`
Expected: PASS.

- [ ] **Step 10: Commit**

```bash
git add lib/Deploy/Config.pm lib/Deploy/Manifest.pm 321.yml t/33-config-ssh-targets.t t/10-manifest.t
git commit -m "Config: SSH target fields, 321.yml manifest rename, target from CLI"
```

---

## Task 5: Refactor Deploy::Service to use Transport

Replace all direct shell calls in `Deploy::Service` with transport calls. This is the core refactor — every operation becomes transport-aware.

**Files:**
- Modify: `lib/Deploy/Service.pm`
- Create: `t/34-service-with-transport.t`

- [ ] **Step 1: Write failing tests**

Create `t/34-service-with-transport.t`:

```perl
use strict;
use warnings;
use Test::More;
use Path::Tiny qw(tempdir path);
use Deploy::Config;
use Deploy::Service;
use Deploy::Local;
use Mojo::Log;

sub make_fixture {
    my $home = tempdir(CLEANUP => 1);
    path($home, 'services')->mkpath;
    path($home, 'secrets')->mkpath;

    my $repo = tempdir(CLEANUP => 1);
    system("cd $repo && git init -q && git config user.email t\@t && git config user.name t && git commit --allow-empty -m init -q");
    path($repo, 'cpanfile')->spew_utf8("requires 'perl', '5.010';\n");
    path($repo, '321.yml')->spew_utf8("name: demo.web\nentry: bin/app.pl\nrunner: hypnotoad\n");

    path($home, 'services', 'demo.web.yml')->spew_utf8(<<"YAML");
name: demo.web
repo: $repo
branch: master
targets:
  dev:
    host: demo.do.dev
    port: 39400
    runner: morbo
YAML

    return ($home, $repo);
}

subtest 'service accepts transport attribute' => sub {
    my ($home, $repo) = make_fixture();
    my $svc_mgr = Deploy::Service->new(
        config    => Deploy::Config->new(app_home => $home, target => 'dev'),
        log       => Mojo::Log->new(level => 'fatal'),
        transport => Deploy::Local->new,
    );
    ok $svc_mgr->transport, 'transport is set';
    isa_ok $svc_mgr->transport, 'Deploy::Local';
};

subtest 'deploy uses transport for commands' => sub {
    my ($home, $repo) = make_fixture();
    my $svc_mgr = Deploy::Service->new(
        config    => Deploy::Config->new(app_home => $home, target => 'dev'),
        log       => Mojo::Log->new(level => 'fatal'),
        transport => Deploy::Local->new,
    );
    my $r = $svc_mgr->deploy('demo.web', skip_git => 1);
    # Deploy will fail at ubic_restart (no ubic in test env) but should
    # get through apt_deps and cpanm steps via transport
    my @steps = map { $_->{step} } @{ $r->{data}{steps} };
    ok scalar @steps > 0, 'got steps from deploy';
    is $steps[0], 'apt_deps', 'first step is apt_deps';
};

subtest 'status uses transport for git sha' => sub {
    my ($home, $repo) = make_fixture();
    my $svc_mgr = Deploy::Service->new(
        config    => Deploy::Config->new(app_home => $home, target => 'dev'),
        log       => Mojo::Log->new(level => 'fatal'),
        transport => Deploy::Local->new,
    );
    my $s = $svc_mgr->status('demo.web');
    ok $s->{git_sha}, 'got git sha via transport';
    like $s->{git_sha}, qr/^[0-9a-f]+$/, 'sha is hex';
};

done_testing;
```

- [ ] **Step 2: Run tests — should fail**

Run: `prove -lv t/34-service-with-transport.t`
Expected: FAIL — `Deploy::Service` doesn't accept `transport` yet.

- [ ] **Step 3: Refactor Deploy::Service**

In `lib/Deploy/Service.pm`, add the transport attribute and refactor all shell calls.

Add attribute (after existing `has` lines, around line 8):

```perl
has 'transport';   # Deploy::Local or Deploy::SSH
```

Replace `_run_in_dir` (lines 272-287) with:

```perl
sub _run_in_dir ($self, $dir, $cmd, %opts) {
    my $timeout = $opts{timeout} // 600;
    $self->log->info("Running: cd $dir && $cmd");
    return $self->transport->run_in_dir($dir, $cmd, timeout => $timeout);
}
```

Replace `_run_cmd` (lines 289-303) with:

```perl
sub _run_cmd ($self, $cmd) {
    $self->log->info("Running: $cmd");
    return $self->transport->run($cmd, timeout => 120);
}
```

Replace `_get_pid` (lines 305-322) with:

```perl
sub _get_pid ($self, $name, $svc) {
    my $r = $self->transport->run("ubic status $name");
    if ($r->{ok} && $r->{output} =~ /running \(pid (\d+)\)/) {
        return $1;
    }
    return undef;
}
```

Replace `_git_sha` (lines 324-328) with:

```perl
sub _git_sha ($self, $repo) {
    my $r = $self->transport->run_in_dir($repo, 'git rev-parse --short HEAD');
    return undef unless $r->{ok};
    chomp(my $sha = $r->{output});
    return $sha || undef;
}
```

Replace `_check_port` (lines 330-344) with:

```perl
sub _check_port ($self, $port) {
    return 0 unless $port;
    my $r = $self->transport->run("bash -c 'echo > /dev/tcp/127.0.0.1/$port' 2>/dev/null", timeout => 5);
    return $r->{ok} ? 1 : 0;
}
```

Replace `_check_apt_deps` (lines 236-249) with:

```perl
sub _check_apt_deps ($self, $svc) {
    my $deps = $svc->{apt_deps} // [];
    return (1, 'no apt_deps declared') unless @$deps;

    my @missing;
    for my $pkg (@$deps) {
        my $r = $self->transport->run("dpkg -s \Q$pkg\E >/dev/null 2>&1");
        push @missing, $pkg unless $r->{ok};
    }

    return (1, 'all installed: ' . join(' ', @$deps)) unless @missing;

    my $cmd = 'sudo apt install -y ' . join(' ', @missing);
    return (0, "Missing system packages: " . join(', ', @missing) . "\n\nRun:\n  $cmd");
}
```

Update step helpers to use new `_run_in_dir` / `_run_cmd` return format. The transport returns `{ok, output}` instead of `($ok, $output)`. Update each `_step_*` method:

Replace `_step_apt_deps` (line 100-103):

```perl
sub _step_apt_deps ($self, $svc) {
    my ($ok, $out) = $self->_check_apt_deps($svc);
    return { step => 'apt_deps', success => $ok ? \1 : \0, output => $out };
}
```

(No change needed — `_check_apt_deps` still returns `($ok, $out)`.)

Replace `_step_git_pull` (lines 105-110):

```perl
sub _step_git_pull ($self, $svc) {
    my $branch = $svc->{branch} // 'master';
    my $r = $self->_run_in_dir($svc->{repo},
        "git fetch origin && git reset --hard origin/$branch");
    return { step => 'git_pull', success => $r->{ok} ? \1 : \0, output => $r->{output} };
}
```

Replace `_step_cpanm` (lines 112-115):

```perl
sub _step_cpanm ($self, $svc) {
    my $r = $self->_run_in_dir($svc->{repo}, $self->_cpanm_cmd($svc->{perlbrew}));
    return { step => 'cpanm', success => $r->{ok} ? \1 : \0, output => $r->{output} };
}
```

Replace `_step_ubic_restart` (lines 117-120):

```perl
sub _step_ubic_restart ($self, $name) {
    my $r = $self->_run_cmd("ubic restart $name");
    return { step => 'ubic_restart', success => $r->{ok} ? \1 : \0, output => $r->{output} };
}
```

Replace `_step_migrate` (lines 122-127):

```perl
sub _step_migrate ($self, $svc) {
    my $repo = $svc->{repo};
    my $env_prefix = "PERL5LIB=$repo/local/lib/perl5 PATH=$repo/local/bin:\$PATH";
    my $r = $self->_run_in_dir($repo, "$env_prefix ./bin/migrate");
    return { step => 'migrate', success => $r->{ok} ? \1 : \0, output => $r->{output} };
}
```

Replace `_step_port_check` (lines 134-141):

```perl
sub _step_port_check ($self, $svc) {
    my $ok = $self->_check_port($svc->{port});
    return {
        step    => 'port_check',
        success => $ok ? \1 : \0,
        output  => $ok ? "Port $svc->{port} responding" : "Port $svc->{port} not responding",
    };
}
```

- [ ] **Step 4: Run new tests — should pass**

Run: `prove -lv t/34-service-with-transport.t`
Expected: PASS.

- [ ] **Step 5: Run full suite — check regressions**

Run: `prove -lr t`

Some existing tests create `Deploy::Service->new(config => ..., log => ...)` without a transport. Add a default transport. In `Deploy::Service`, change the `transport` attribute:

```perl
has 'transport' => sub { Deploy::Local->new };
```

Add at the top of `lib/Deploy/Service.pm`:

```perl
use Deploy::Local;
```

- [ ] **Step 6: Run full suite — confirm clean**

Run: `prove -lr t`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add lib/Deploy/Service.pm t/34-service-with-transport.t
git commit -m "Refactor Deploy::Service to use Transport for all shell calls"
```

---

## Task 6: Deploy::Command base — target resolution from CLI args

Add target parsing to the base command class so all subcommands can accept `[target]` as the last argument.

**Files:**
- Modify: `lib/Deploy/Command.pm`

- [ ] **Step 1: Update Deploy::Command with target parsing**

In `lib/Deploy/Command.pm`, add these methods after `resolve_service`:

```perl
sub parse_target ($self, @args) {
    # Last arg is a target if it matches a known target name in any service config
    # Returns ($service_name, $target_name)
    return (undef, 'dev') unless @args;

    if (@args == 1) {
        # Could be just a service name (target defaults to dev)
        return ($args[0], 'dev');
    }

    # Two args: service + target
    my ($svc_input, $target_input) = @args;
    return ($svc_input, $target_input);
}

sub transport_for ($self, $name, $target) {
    require Deploy::Transport;
    my $cfg = $self->config;
    # Temporarily switch target to resolve the right config
    my $old_target = $cfg->target;
    $cfg->target($target);
    my $svc = $cfg->service($name);
    $cfg->target($old_target);
    return undef unless $svc;
    return Deploy::Transport->for_target($svc, perlbrew => $svc->{perlbrew});
}
```

- [ ] **Step 2: Run full suite — no regressions**

Run: `prove -lr t`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add lib/Deploy/Command.pm
git commit -m "Add target parsing and transport factory to base command"
```

---

## Task 7: Update lifecycle commands to accept target

Update all lifecycle subcommands (`start`, `stop`, `restart`, `go`, `update`, `migrate`, `status`, `list`) to accept an optional target argument and pass transport through.

**Files:**
- Modify: `lib/Deploy/Command/start.pm`
- Modify: `lib/Deploy/Command/stop.pm`
- Modify: `lib/Deploy/Command/restart.pm`
- Modify: `lib/Deploy/Command/go.pm`
- Modify: `lib/Deploy/Command/update.pm`
- Modify: `lib/Deploy/Command/migrate.pm`
- Modify: `lib/Deploy/Command/status.pm`
- Modify: `lib/Deploy/Command/list.pm`

- [ ] **Step 1: Update `start.pm`**

Replace the `run` method in `lib/Deploy/Command/start.pm`:

```perl
sub run ($self, @args) {
    my ($svc_input, $target) = $self->parse_target(@args);
    die $self->usage unless $svc_input;
    my $name = $self->resolve_service($svc_input);
    my $transport = $self->transport_for($name, $target);
    my $r = $transport->run("ubic start $name");
    if ($r->{ok}) {
        say "  $name started ($target)";
    } else {
        say "  $name start failed: $r->{output}";
    }
}
```

- [ ] **Step 2: Update `stop.pm`**

Replace the `run` method in `lib/Deploy/Command/stop.pm`:

```perl
sub run ($self, @args) {
    my ($svc_input, $target) = $self->parse_target(@args);
    die $self->usage unless $svc_input;
    my $name = $self->resolve_service($svc_input);
    my $transport = $self->transport_for($name, $target);
    my $r = $transport->run("ubic stop $name");
    if ($r->{ok}) {
        say "  $name stopped ($target)";
    } else {
        say "  $name stop failed: $r->{output}";
    }
}
```

- [ ] **Step 3: Update `restart.pm`**

Replace the `run` method in `lib/Deploy/Command/restart.pm`:

```perl
sub run ($self, @args) {
    my ($svc_input, $target) = $self->parse_target(@args);
    die $self->usage unless $svc_input;
    my $name = $self->resolve_service($svc_input);
    my $transport = $self->transport_for($name, $target);

    my $svc_mgr = $self->svc_mgr;
    $svc_mgr->transport($transport);
    my $r = $svc_mgr->restart($name);
    for my $step (@{ $r->{data}{steps} // [] }) {
        my $ok = $self->svc_mgr->_ok($step);
        printf "  [%s] %s\n", ($ok ? 'OK' : 'FAIL'), $step->{step};
    }
    say "  $r->{message}" if $r->{message};
}
```

- [ ] **Step 4: Update `go.pm`**

Replace the `run` method in `lib/Deploy/Command/go.pm`:

```perl
sub run ($self, @args) {
    my ($svc_input, $target) = $self->parse_target(@args);
    die $self->usage unless $svc_input;
    my $name = $self->resolve_service($svc_input);
    my $transport = $self->transport_for($name, $target);

    my $svc_mgr = $self->svc_mgr;
    $svc_mgr->transport($transport);

    say "3... 2... 1... deploying $name ($target)";
    my $skip_git = ($target eq 'dev') ? 1 : 0;
    my $r = $svc_mgr->deploy($name, skip_git => $skip_git);
    for my $step (@{ $r->{data}{steps} // [] }) {
        my $ok = $svc_mgr->_ok($step);
        printf "  [%s] %s\n", ($ok ? 'OK' : 'FAIL'), $step->{step};
    }
    say "  $r->{message}" if $r->{message};
}
```

- [ ] **Step 5: Update `update.pm`**

Replace the `run` method in `lib/Deploy/Command/update.pm`:

```perl
sub run ($self, @args) {
    my ($svc_input, $target) = $self->parse_target(@args);
    die $self->usage unless $svc_input;
    my $name = $self->resolve_service($svc_input);
    my $transport = $self->transport_for($name, $target);

    my $svc_mgr = $self->svc_mgr;
    $svc_mgr->transport($transport);
    my $r = $svc_mgr->update($name);
    for my $step (@{ $r->{data}{steps} // [] }) {
        my $ok = $svc_mgr->_ok($step);
        printf "  [%s] %s\n", ($ok ? 'OK' : 'FAIL'), $step->{step};
    }
    say "  $r->{message}" if $r->{message};
}
```

- [ ] **Step 6: Update `migrate.pm`**

Replace the `run` method in `lib/Deploy/Command/migrate.pm`:

```perl
sub run ($self, @args) {
    my ($svc_input, $target) = $self->parse_target(@args);
    die $self->usage unless $svc_input;
    my $name = $self->resolve_service($svc_input);
    my $transport = $self->transport_for($name, $target);

    my $svc_mgr = $self->svc_mgr;
    $svc_mgr->transport($transport);
    my $r = $svc_mgr->migrate($name);
    for my $step (@{ $r->{data}{steps} // [] }) {
        my $ok = $svc_mgr->_ok($step);
        printf "  [%s] %s\n", ($ok ? 'OK' : 'FAIL'), $step->{step};
    }
    say "  $r->{message}" if $r->{message};
}
```

- [ ] **Step 7: Update `status.pm`**

Replace the `run` method in `lib/Deploy/Command/status.pm`:

```perl
sub run ($self, @args) {
    my ($svc_input, $target) = $self->parse_target(@args);
    my $transport;

    if ($svc_input) {
        my $name = $self->resolve_service($svc_input);
        $transport = $self->transport_for($name, $target);
        $self->svc_mgr->transport($transport);
        my $r = $transport->run("ubic status $name");
        say $r->{output};
    } else {
        # All services — use target transport for each
        $transport = $self->transport_for(($self->config->service_names->[0] // return), $target);
        my $r = $transport->run("ubic status");
        say $r->{output};
    }
}
```

- [ ] **Step 8: Update `list.pm`**

Replace the `run` method in `lib/Deploy/Command/list.pm`:

```perl
sub run ($self, @args) {
    my (undef, $target) = $self->parse_target(@args);
    my $cfg = $self->config;
    $cfg->target($target);

    for my $name (@{ $cfg->service_names }) {
        my $svc = $cfg->service($name);
        printf "  %-20s %-5s %-12s port %s\n",
            $name,
            uc($svc->{mode} eq 'development' ? 'DEV' : 'LIVE'),
            $svc->{runner},
            $svc->{port} // '-';
    }
}
```

- [ ] **Step 9: Run full suite**

Run: `prove -lr t`
Expected: PASS.

- [ ] **Step 10: Commit**

```bash
git add lib/Deploy/Command/start.pm lib/Deploy/Command/stop.pm \
        lib/Deploy/Command/restart.pm lib/Deploy/Command/go.pm \
        lib/Deploy/Command/update.pm lib/Deploy/Command/migrate.pm \
        lib/Deploy/Command/status.pm lib/Deploy/Command/list.pm
git commit -m "All lifecycle commands accept [target] argument and use transport"
```

---

## Task 8: Logs command with transport

**Files:**
- Create: `lib/Deploy/Command/logs.pm`
- Modify: `lib/Deploy/Logs.pm`

- [ ] **Step 1: Add transport to Deploy::Logs**

In `lib/Deploy/Logs.pm`, add transport attribute and refactor `tail` to use it:

```perl
has 'transport';

sub tail ($self, $name, %opts) {
    my $type = $opts{type} // 'stderr';
    my $n    = $opts{n} // 100;
    $n = 1000 if $n > 1000;

    my $svc = $self->config->service($name);
    return { status => 'error', message => "Unknown service: $name" } unless $svc;

    my $logfile = $svc->{logs}{$type};
    return { status => 'error', message => "No $type log configured for $name" } unless $logfile;

    if ($self->transport) {
        my $r = $self->transport->run("tail -n $n $logfile");
        return {
            status => $r->{ok} ? 'success' : 'error',
            data   => { lines => [split /\n/, $r->{output}], type => $type, file => $logfile },
        };
    }

    # Local fallback (existing behaviour)
    return $self->_tail_local($logfile, $type, $n);
}
```

Add a `stream` method for `tail -f`:

```perl
sub stream ($self, $name, %opts) {
    my $type = $opts{type} // 'stdout';
    my $svc = $self->config->service($name);
    return { status => 'error', message => "Unknown service: $name" } unless $svc;

    my $logfile = $svc->{logs}{$type};
    return { status => 'error', message => "No $type log configured for $name" } unless $logfile;

    say "Streaming $type for $name: $logfile";
    say "Press Ctrl-C to stop.\n";
    $self->transport->stream("tail -f $logfile", on_line => $opts{on_line});
}
```

- [ ] **Step 2: Create `lib/Deploy/Command/logs.pm`**

```perl
package Deploy::Command::logs;

use Mojo::Base 'Deploy::Command', -signatures;

has description => 'Tail, search, or analyse service logs';
has usage => sub ($self) { $self->extract_usage };

sub run ($self, @args) {
    # Parse options from args
    my %opts;
    my @positional;
    for my $arg (@args) {
        if ($arg =~ /^--stderr$/)        { $opts{type} = 'stderr' }
        elsif ($arg =~ /^--ubic$/)       { $opts{type} = 'ubic' }
        elsif ($arg =~ /^--search=(.+)/) { $opts{search} = $1 }
        elsif ($arg =~ /^--analyse$/)    { $opts{analyse} = 1 }
        elsif ($arg =~ /^--n=(\d+)/)     { $opts{n} = $1 }
        else                             { push @positional, $arg }
    }

    my ($svc_input, $target) = $self->parse_target(@positional);
    die $self->usage unless $svc_input;
    my $name = $self->resolve_service($svc_input);
    my $transport = $self->transport_for($name, $target);

    my $log_mgr = $self->app->log_mgr_obj;
    $log_mgr->transport($transport);

    if ($opts{search}) {
        my $r = $log_mgr->search($name, $opts{search},
            type => $opts{type} // 'stderr', n => $opts{n} // 50);
        if ($r->{status} eq 'success') {
            say $_ for @{ $r->{data}{matches} // [] };
        } else {
            say "Error: $r->{message}";
        }
    } elsif ($opts{analyse}) {
        my $r = $log_mgr->analyse($name, n => $opts{n} // 1000);
        if ($r->{status} eq 'success') {
            my $d = $r->{data};
            say "Errors: $d->{error_count}  Warnings: $d->{warning_count}";
            for my $e (@{ $d->{top_errors} // [] }) {
                printf "  [%d] %s\n", $e->{count}, $e->{pattern};
            }
        } else {
            say "Error: $r->{message}";
        }
    } else {
        # Default: streaming tail
        $log_mgr->stream($name, type => $opts{type} // 'stdout');
    }
}

1;

=head1 SYNOPSIS

  Usage: APPLICATION logs <service> [target] [options]

  Options:
    --stderr        Tail stderr instead of stdout
    --ubic          Tail ubic log
    --search=TERM   Search logs for TERM
    --analyse       Show error/warning summary
    --n=NUM         Number of lines (default: 100 for tail, 50 for search)

  Examples:
    321 logs love.web              # tail local stdout
    321 logs love.web live         # tail remote stdout
    321 logs love.web --stderr     # tail local stderr
    321 logs love.web live --search=ERROR
    321 logs love.web --analyse

=cut
```

- [ ] **Step 3: Run full suite**

Run: `prove -lr t`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add lib/Deploy/Logs.pm lib/Deploy/Command/logs.pm
git commit -m "Add logs CLI command with tail/search/analyse via transport"
```

---

## Task 9: Rebuild command (replaces generate)

**Files:**
- Create: `lib/Deploy/Command/rebuild.pm`
- Delete: `lib/Deploy/Command/generate.pm`

- [ ] **Step 1: Create `lib/Deploy/Command/rebuild.pm`**

```perl
package Deploy::Command::rebuild;

use Mojo::Base 'Deploy::Command', -signatures;
use Deploy::Hosts;

has description => 'Regenerate all ubic service files + symlinks';
has usage => sub ($self) { $self->extract_usage };

sub run ($self, @args) {
    my (undef, $target) = $self->parse_target(@args);

    say "Rebuilding ubic service files ($target)...";

    my $ubic = $self->ubic;
    $ubic->generate_all;
    $ubic->install_symlinks;

    say "Done.";

    # Update /etc/hosts (local only, best-effort)
    if ($target eq 'dev') {
        my $dev_hosts = $self->config->dev_hostnames;
        if (@$dev_hosts && -w '/etc/hosts') {
            Deploy::Hosts->new->write($dev_hosts);
            say "  /etc/hosts updated (" . scalar(@$dev_hosts) . " dev hosts)";
        } elsif (@$dev_hosts) {
            say "  /etc/hosts not writable - run 'sudo -E perl bin/321.pl hosts' to update";
        }
    }
}

1;

=head1 SYNOPSIS

  Usage: APPLICATION rebuild [target]

  Regenerates all ubic service files from config and reinstalls symlinks.

  321 rebuild         # local dev
  321 rebuild live    # remote (future: regenerate on remote server)

=cut
```

- [ ] **Step 2: Delete old generate command**

```bash
git rm lib/Deploy/Command/generate.pm
```

- [ ] **Step 3: Run full suite**

Run: `prove -lr t`
Expected: PASS (no tests directly tested the `generate` command).

- [ ] **Step 4: Commit**

```bash
git add lib/Deploy/Command/rebuild.pm
git commit -m "Replace generate command with rebuild"
```

---

## Task 10: Dash command (local dashboard)

**Files:**
- Create: `lib/Deploy/Command/dash.pm`

- [ ] **Step 1: Create `lib/Deploy/Command/dash.pm`**

```perl
package Deploy::Command::dash;

use Mojo::Base 'Deploy::Command', -signatures;

has description => 'Start the local web dashboard';
has usage => sub ($self) { $self->extract_usage };

sub run ($self, @args) {
    my $port = 9321;
    say "Starting 321 dashboard on http://127.0.0.1:$port";
    say "Press Ctrl-C to stop.\n";
    $self->app->start('daemon', '-l', "http://127.0.0.1:$port");
}

1;

=head1 SYNOPSIS

  Usage: APPLICATION dash

  Starts the local 321 web dashboard on port 9321.

=cut
```

- [ ] **Step 2: Commit**

```bash
git add lib/Deploy/Command/dash.pm
git commit -m "Add dash command for local web dashboard"
```

---

## Task 11: Install command — full remote bootstrap via transport

Rewrite the install command to work remotely via SSH transport.

**Files:**
- Modify: `lib/Deploy/Command/install.pm`

- [ ] **Step 1: Rewrite `lib/Deploy/Command/install.pm`**

```perl
package Deploy::Command::install;

use Mojo::Base 'Deploy::Command', -signatures;

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

    # Check manifest
    $r = $transport->run("test -f $repo/321.yml && echo FOUND");
    unless ($r->{output} =~ /FOUND/) {
        die "  No 321.yml manifest in $repo. Every service repo must ship one.\n";
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
        # Upload the generated file to the remote server
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
            warn "  [WARN] $provider failed — run manually later\n";
        }
    }

    say "";
    say "  $name installed on $target.";
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

  Usage: APPLICATION install <service> [target]

  First-time setup: clone, perlbrew, deps, ubic, nginx, SSL.

  321 install love.web         # install locally
  321 install love.web live    # install on remote server via SSH

=cut
```

- [ ] **Step 2: Delete old install.pl**

```bash
git rm bin/install.pl
```

- [ ] **Step 3: Commit**

```bash
git add lib/Deploy/Command/install.pm
git commit -m "Rewrite install command for remote bootstrap via transport"
```

---

## Task 12: Simplify bin/321.pl — strip auth, drop APIs, add target dropdown

Strip the production web service features. Keep only the local dashboard routes.

**Files:**
- Modify: `bin/321.pl`

- [ ] **Step 1: Remove auth guard**

In `bin/321.pl`, find the `under '/'` auth block (lines 88-121). Replace with:

```perl
# No auth — dashboard is local-only
```

- [ ] **Step 2: Remove target cookie mechanism**

Remove the `active_target` helper (line 65-67) and the `POST /target` + `GET /target` routes (lines 466-484). Target is now a CLI argument, not a cookie.

Add a simple helper for the dashboard's target selection:

```perl
helper available_targets => sub ($c) {
    my @targets;
    for my $name (@{ $c->config_obj->service_names }) {
        my $raw = $c->config_obj->service_raw($name);
        push @targets, sort keys %{ $raw->{targets} // {} };
    }
    my %seen;
    return [ grep { !$seen{$_}++ } @targets ];
};
```

- [ ] **Step 3: Remove JSON API routes that duplicate CLI**

Remove these routes (they were for the production web service; the dashboard calls modules directly):
- `POST /service/:name/deploy` (line 171)
- `POST /service/:name/deploy-dev` (line 181)
- `POST /service/:name/update` (line 191)
- `POST /service/:name/migrate` (line 199)
- `POST /service/:name/config` (POST, line 300)
- `POST /services/create` (line 313)
- `POST /service/:name/delete` (line 336)
- `POST /git/push` (line 362)
- `POST /services/generate-ubic` (line 279)
- All secrets routes (lines 415-462)

Keep these routes (dashboard needs them):
- `GET /health` — local health check
- `GET /services` — service list for dashboard
- `GET /service/:name/status` — service status
- `GET /service/:name/logs` — log tail
- `GET /service/:name/logs/search` — log search
- `GET /service/:name/logs/analyse` — log analysis
- `GET /service/:name/nginx` — nginx status
- `POST /service/:name/restart` — dashboard restart button
- `POST /service/:name/deploy` — dashboard deploy button (keep this one)
- `GET /git/status` — git info
- `GET /` — dashboard
- `GET /ui/service/:name` — service detail

- [ ] **Step 4: Add target parameter to kept routes**

Update the remaining routes to accept a `target` query param:

```perl
# In each route handler, add at the top:
my $target = $c->param('target') // 'dev';
$c->config_obj->target($target);
```

For the deploy and restart POST routes, create a transport and pass it to the service manager:

```perl
post '/service/#name/deploy' => sub ($c) {
    my $name   = $c->param('name');
    my $target = $c->param('target') // 'dev';
    return unless $c->validate_service($name);

    $c->config_obj->target($target);
    my $svc = $c->config_obj->service($name);
    my $transport = Deploy::Transport->for_target($svc, perlbrew => $svc->{perlbrew});
    $c->svc_mgr->transport($transport);

    my $skip_git = ($target eq 'dev') ? 1 : 0;
    my $result = $c->svc_mgr->deploy($name, skip_git => $skip_git);
    $c->render(json => $result);
};
```

- [ ] **Step 5: Remove deploy_token and secrets helpers**

Remove `deploy_token` helper and `secrets_mgr` helper. Remove `use Deploy::Secrets` from imports.

- [ ] **Step 6: Run full suite**

Run: `prove -lr t`
Expected: Some test failures from removed routes — update or remove affected tests.

- [ ] **Step 7: Remove tests for dropped routes**

Delete or update tests that test removed routes:
- `t/05-basic-auth.t` — delete (no auth)
- `t/11-secrets.t` — keep (module still exists for manual use)
- `t/13-secrets-endpoints.t` — delete (endpoints removed)
- `t/16-deploy-blocks-on-missing-secrets.t` — keep or delete depending on whether deploy still checks secrets

- [ ] **Step 8: Run full suite — confirm clean**

Run: `prove -lr t`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add bin/321.pl
git rm t/05-basic-auth.t t/13-secrets-endpoints.t
git commit -m "Simplify dashboard: strip auth, drop redundant API routes, add target param"
```

---

## Task 13: Update Nginx to use transport for system commands

**Files:**
- Modify: `lib/Deploy/Nginx.pm`

- [ ] **Step 1: Add transport attribute**

Add to `lib/Deploy/Nginx.pm` after existing `has` declarations:

```perl
has 'transport';
```

- [ ] **Step 2: Update `test` method**

Replace `test` method (lines 58-62):

```perl
sub test ($self) {
    if ($self->transport) {
        my $r = $self->transport->run('sudo nginx -t');
        return { ok => $r->{ok}, output => $r->{output} };
    }
    my $output = `nginx -t 2>&1`;
    return { ok => ($? == 0), output => $output };
}
```

- [ ] **Step 3: Update `reload` method**

Replace `reload` method (lines 64-72):

```perl
sub reload ($self) {
    my $test = $self->test;
    return { status => 'error', message => "nginx -t failed: $test->{output}" } unless $test->{ok};

    if ($self->transport) {
        my $r = $self->transport->run('sudo systemctl reload nginx');
        return { status => $r->{ok} ? 'ok' : 'error', output => $r->{output} };
    }
    my $output = `systemctl reload nginx 2>&1`;
    return { status => ($? == 0 ? 'ok' : 'error'), output => $output };
}
```

- [ ] **Step 4: Update `generate` to write via transport**

In the `generate` method, after rendering the config, write via transport if remote:

```perl
if ($self->transport && $self->transport->isa('Deploy::SSH')) {
    # Write locally to temp, upload, then move into place
    require File::Temp;
    my $tmp = File::Temp->new(SUFFIX => '.conf');
    print $tmp $conf;
    close $tmp;
    $self->transport->upload($tmp->filename, "/tmp/$host.conf");
    $self->transport->run("sudo mv /tmp/$host.conf /etc/nginx/sites-available/$host");
} else {
    my $file = path($self->sites_available, $host);
    $file->spew_utf8($conf);
}
```

- [ ] **Step 5: Run full suite**

Run: `prove -lr t`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/Deploy/Nginx.pm
git commit -m "Nginx: use transport for nginx -t, reload, and remote config writes"
```

---

## Task 14: Delete dropped files, clean up

**Files:**
- Delete: `lib/Deploy/Secrets.pm`
- Delete: `bin/install.pl`
- Delete: `t/05-basic-auth.t` (if not already deleted)

- [ ] **Step 1: Remove files**

```bash
git rm lib/Deploy/Secrets.pm bin/install.pl
git rm t/05-basic-auth.t t/13-secrets-endpoints.t 2>/dev/null || true
```

- [ ] **Step 2: Remove Deploy::Secrets usage from bin/321.pl**

Remove the `use Deploy::Secrets` line and the `secrets_mgr` initialization from `bin/321.pl` (around line 48).

- [ ] **Step 3: Run full suite**

Run: `prove -lr t`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add bin/321.pl
git commit -m "Remove Deploy::Secrets, bin/install.pl, auth tests"
```

---

## Task 15: End-to-end smoke test — local

Verify the whole system works locally.

- [ ] **Step 1: Test CLI commands locally**

```bash
perl bin/321.pl list
perl bin/321.pl status 321.web
perl bin/321.pl logs 321.web --stderr --n=5
```

Expected: list shows services, status shows running state, logs shows last 5 stderr lines.

- [ ] **Step 2: Test dashboard**

```bash
perl bin/321.pl dash &
curl -s http://127.0.0.1:9321/health | jq .
curl -s http://127.0.0.1:9321/services | jq .status
kill %1
```

Expected: health returns `success`, services returns list.

- [ ] **Step 3: Run full suite one last time**

```bash
prove -lr t
```

Expected: PASS.

- [ ] **Step 4: Commit any final fixes**

```bash
git add -A
git commit -m "Final cleanup: end-to-end smoke test passing"
```

---

## Self-Review Checklist

- [x] Every spec requirement has a task: Transport (Tasks 1-3), Config SSH targets (Task 4), Service refactor (Task 5), CLI target arg (Tasks 6-7), Logs CLI (Task 8), Rebuild command (Task 9), Dash command (Task 10), Install via SSH (Task 11), Dashboard simplification (Task 12), Nginx transport (Task 13), Cleanup (Task 14), Smoke test (Task 15).
- [x] No placeholders — every code step has runnable code.
- [x] Method names consistent: `run`, `run_in_dir`, `run_steps`, `stream`, `upload` on both Local and SSH. `for_target` on Transport. `parse_target`, `transport_for` on Command base.
- [x] File paths exact throughout.
- [x] `321.yml` (not `.321.yml`) used everywhere.
- [x] Commit per task.
- [x] TDD pattern: write test → verify fail → implement → verify pass → commit.
- [x] Transport interface identical between Local and SSH — callers never care.
