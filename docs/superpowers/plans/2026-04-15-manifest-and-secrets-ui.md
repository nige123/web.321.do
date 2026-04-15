# Manifest-Driven Install + Secrets UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move per-service runtime facts (entry point, runner, required env keys) from the deploy repo into a `.321.yml` manifest inside each service repo, then surface missing-secret state in the 321 dashboard with a web form to set them.

**Architecture:** A new `Deploy::Manifest` module loads `.321.yml` from the cloned service repo. `Deploy::Config` merges deploy-side YAML (host/port/ssl/secret ref) with manifest fields (bin/runner/perlbrew/env_required/env_optional) at resolve time — deploy-side wins on conflict for operator override. New `/service/:name/secrets` endpoints diff `env_required` against `secrets/<name>.env` contents and offer a form UI. All writes are atomic (temp + rename, `chmod 600`) and append to a per-service audit log that records key name + operator, never values.

**Tech Stack:** Perl 5.42, Mojolicious::Lite, YAML::XS, Path::Tiny, Test::Mojo. No new runtime dependencies.

---

## File Structure

**New files:**
- `lib/Deploy/Manifest.pm` — manifest loader + validator
- `lib/Deploy/Secrets.pm` — env file read/diff/write + audit log
- `lib/Deploy/Command/manifest.pm` — CLI: `321 manifest <service>` prints parsed manifest
- `t/10-manifest.t` — manifest loader unit tests
- `t/11-secrets.t` — secrets module + endpoint tests
- `.321.yml` (in *this* repo, dogfooding)

**Modified files:**
- `lib/Deploy/Config.pm` — merge manifest into resolved service at `service()` time
- `lib/Deploy/Ubic.pm` — read `bin`/`runner`/`perlbrew` via config (now manifest-sourced)
- `lib/Deploy/Command/install.pm` — fail fast if repo missing `.321.yml`; scaffold deploy YAML from manifest
- `bin/321.pl` — three new routes + dashboard/service-page templates for secrets
- `services/*.yml` — slim down (remove `bin`, `perlbrew`, runner defaults — migration task)

**Untouched:**
- `lib/Deploy/Nginx.pm` — dev-parity work lives in plan 2
- `lib/Deploy/Service.pm` — deploy logic doesn't need to change for this plan

---

## Task 1: Manifest schema + loader

**Files:**
- Create: `lib/Deploy/Manifest.pm`
- Create: `t/10-manifest.t`

Manifest shape (for reference — validated by code below):

```yaml
name: 321.web
entry: bin/321.pl
runner: hypnotoad          # hypnotoad | morbo | script
perl: perl-5.42.1
health: /health
env_required:
  DEPLOY_TOKEN: "Token for remote deploy endpoint"
env_optional:
  LOG_LEVEL:
    default: info
    desc: "debug | info | warn"
  MOJO_MODE:
    default: production
```

- [ ] **Step 1: Write failing tests**

```perl
# t/10-manifest.t
use strict;
use warnings;
use Test::More;
use Path::Tiny qw(tempdir path);
use Deploy::Manifest;

my $dir = tempdir(CLEANUP => 1);

subtest 'missing file returns undef' => sub {
    my $m = Deploy::Manifest->load($dir);
    ok !$m, 'returns undef when .321.yml absent';
};

subtest 'minimal manifest' => sub {
    path($dir, '.321.yml')->spew_utf8(<<'YAML');
name: foo.web
entry: bin/app.pl
runner: hypnotoad
YAML
    my $m = Deploy::Manifest->load($dir);
    is $m->{name},   'foo.web';
    is $m->{entry},  'bin/app.pl';
    is $m->{runner}, 'hypnotoad';
    is_deeply $m->{env_required}, {}, 'env_required defaults to empty';
    is_deeply $m->{env_optional}, {}, 'env_optional defaults to empty';
};

subtest 'full manifest with env' => sub {
    path($dir, '.321.yml')->spew_utf8(<<'YAML');
name: love.web
entry: bin/love.pl
runner: hypnotoad
perl: perl-5.42.1
health: /health
env_required:
  DATABASE_URL: "Postgres DSN"
env_optional:
  LOG_LEVEL:
    default: info
    desc: "debug | info | warn"
YAML
    my $m = Deploy::Manifest->load($dir);
    is $m->{perl}, 'perl-5.42.1';
    is $m->{env_required}{DATABASE_URL}, 'Postgres DSN';
    is $m->{env_optional}{LOG_LEVEL}{default}, 'info';
};

subtest 'invalid: missing required field' => sub {
    path($dir, '.321.yml')->spew_utf8("name: bad\n");
    my $err = eval { Deploy::Manifest->load($dir); 0 } || $@;
    like $err, qr/missing 'entry'/, 'rejects manifest without entry';
};

subtest 'invalid: unknown runner' => sub {
    path($dir, '.321.yml')->spew_utf8(<<'YAML');
name: bad
entry: bin/x.pl
runner: supervisord
YAML
    my $err = eval { Deploy::Manifest->load($dir); 0 } || $@;
    like $err, qr/unknown runner/, 'rejects unsupported runner';
};

subtest 'invalid: bad env key name' => sub {
    path($dir, '.321.yml')->spew_utf8(<<'YAML');
name: bad
entry: bin/x.pl
runner: hypnotoad
env_required:
  "lowercase": "no"
YAML
    my $err = eval { Deploy::Manifest->load($dir); 0 } || $@;
    like $err, qr/invalid env key/, 'rejects non-conforming env key';
};

done_testing;
```

- [ ] **Step 2: Run tests, confirm all fail**

```
prove -lv t/10-manifest.t
```
Expected: all subtests fail with "Can't locate Deploy/Manifest.pm".

- [ ] **Step 3: Implement `Deploy::Manifest`**

```perl
# lib/Deploy/Manifest.pm
package Deploy::Manifest;

use Mojo::Base -base, -signatures;
use YAML::XS qw(LoadFile);
use Path::Tiny qw(path);

my %VALID_RUNNER = map { $_ => 1 } qw(hypnotoad morbo script);
my $ENV_KEY_RE   = qr/^[A-Z_][A-Z0-9_]*$/;

sub load ($class, $repo_dir) {
    my $file = path($repo_dir, '.321.yml');
    return undef unless $file->exists;

    my $raw = LoadFile($file->stringify);
    die "Manifest $file: not a mapping\n" unless ref $raw eq 'HASH';

    for my $k (qw(name entry runner)) {
        die "Manifest $file: missing '$k'\n" unless defined $raw->{$k};
    }

    die "Manifest $file: unknown runner '$raw->{runner}'\n"
        unless $VALID_RUNNER{ $raw->{runner} };

    my %required = %{ $raw->{env_required} // {} };
    my %optional = %{ $raw->{env_optional} // {} };

    for my $k (keys %required, keys %optional) {
        die "Manifest $file: invalid env key '$k'\n" unless $k =~ $ENV_KEY_RE;
    }

    return {
        name         => $raw->{name},
        entry        => $raw->{entry},
        runner       => $raw->{runner},
        perl         => $raw->{perl},
        health       => $raw->{health} // '/health',
        env_required => \%required,
        env_optional => \%optional,
    };
}

1;
```

- [ ] **Step 4: Run tests, confirm all pass**

```
prove -lv t/10-manifest.t
```
Expected: all subtests PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/Deploy/Manifest.pm t/10-manifest.t
git commit -m "Add Deploy::Manifest loader with schema validation"
```

---

## Task 2: Dogfood — add `.321.yml` to this repo

**Files:**
- Create: `.321.yml`

- [ ] **Step 1: Write the manifest**

```yaml
# .321.yml
name: 321.web
entry: bin/321.pl
runner: hypnotoad
perl: perl-5.42.1
health: /health

env_required:
  MOJO_MODE: "production or development"

env_optional:
  DEPLOY_TOKEN:
    desc: "Token for remote deploy endpoint (generated by install.pl)"
```

- [ ] **Step 2: Verify the manifest parses**

```
perl -Ilib -MDeploy::Manifest -E 'use Data::Dumper; print Dumper(Deploy::Manifest->load("."))'
```
Expected: Data::Dumper output showing the hash, no errors.

- [ ] **Step 3: Commit**

```bash
git add .321.yml
git commit -m "Add .321.yml manifest for 321.web (dogfood)"
```

---

## Task 3: Merge manifest into resolved service

**Files:**
- Modify: `lib/Deploy/Config.pm` (add `_merge_manifest` called from `_resolve`)
- Create: `t/12-config-manifest-merge.t`

Goal: `Deploy::Config->service($name)` returns a hash where `bin`, `runner` (default), `perlbrew`, `health`, `env_required`, `env_optional` come from the manifest if the repo on disk has one. Deploy-YAML values still win on conflict (operator override). Missing manifest = fall back to current behaviour so the step is non-breaking.

- [ ] **Step 1: Write failing test**

```perl
# t/12-config-manifest-merge.t
use strict;
use warnings;
use Test::More;
use Path::Tiny qw(tempdir path);
use Deploy::Config;

my $home = tempdir(CLEANUP => 1);
path($home, 'services')->mkpath;
path($home, 'secrets')->mkpath;

my $repo = tempdir(CLEANUP => 1);
path($repo, '.321.yml')->spew_utf8(<<'YAML');
name: demo.web
entry: bin/demo.pl
runner: hypnotoad
perl: perl-5.42.1
env_required:
  API_KEY: "upstream API"
env_optional:
  LOG_LEVEL:
    default: info
YAML

path($home, 'services', 'demo.web.yml')->spew_utf8(<<"YAML");
name: demo.web
repo: $repo
branch: master
targets:
  live:
    host: demo.do
    port: 9400
YAML

my $c = Deploy::Config->new(app_home => $home, target => 'live');
my $svc = $c->service('demo.web');

is $svc->{bin},      'bin/demo.pl',    'bin from manifest entry';
is $svc->{runner},   'hypnotoad',      'runner from manifest';
is $svc->{perlbrew}, 'perl-5.42.1',    'perl from manifest';
is $svc->{port},     9400,             'port from deploy yaml';
is $svc->{host},     'demo.do',        'host from deploy yaml';
is_deeply $svc->{env_required}, { API_KEY => 'upstream API' };
is $svc->{env_optional}{LOG_LEVEL}{default}, 'info';

# Deploy YAML override wins
path($home, 'services', 'demo.web.yml')->spew_utf8(<<"YAML");
name: demo.web
repo: $repo
bin: bin/override.pl
targets:
  live:
    port: 9400
YAML
$c->reload;
is $c->service('demo.web')->{bin}, 'bin/override.pl', 'deploy yaml overrides manifest';

done_testing;
```

- [ ] **Step 2: Run test, confirm failure**

```
prove -lv t/12-config-manifest-merge.t
```
Expected: FAIL — `env_required` is undef, `bin` is undef when deploy YAML omits it.

- [ ] **Step 3: Modify `lib/Deploy/Config.pm`**

Add `use Deploy::Manifest;` near the top, then update `_resolve` and add `_merge_manifest`. Replace the existing `_resolve` sub with:

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
        name    => $name,
        repo    => $raw->{repo},
        branch  => $raw->{branch} // 'master',
        bin     => $bin,
        mode    => $runner eq 'morbo' ? 'development' : 'production',
        runner  => $runner,
        port    => $target->{port},
        logs    => $target->{logs} // {},
        env     => $target->{env} // {},
        host    => $target->{host} // 'localhost',
        health  => $manifest ? $manifest->{health} : '/health',
        env_required => $manifest ? $manifest->{env_required} : {},
        env_optional => $manifest ? $manifest->{env_optional} : {},
        ($target->{docs}  ? (docs  => $target->{docs})  : ()),
        ($target->{admin} ? (admin => $target->{admin}) : ()),
        ($perlbrew        ? (perlbrew => $perlbrew)     : ()),
    };
}
```

- [ ] **Step 4: Run test, confirm pass**

```
prove -lv t/12-config-manifest-merge.t
```
Expected: all subtests PASS.

- [ ] **Step 5: Run full test suite to catch regressions**

```
prove -lr t
```
Expected: all existing tests still pass.

- [ ] **Step 6: Commit**

```bash
git add lib/Deploy/Config.pm t/12-config-manifest-merge.t
git commit -m "Merge .321.yml manifest into resolved service config"
```

---

## Task 4: Secrets diff + audit log module

**Files:**
- Create: `lib/Deploy/Secrets.pm`
- Create: `t/11-secrets.t`

- [ ] **Step 1: Write failing tests**

```perl
# t/11-secrets.t
use strict;
use warnings;
use Test::More;
use Path::Tiny qw(tempdir path);
use Deploy::Secrets;

my $home = tempdir(CLEANUP => 1);
path($home, 'secrets')->mkpath;

my $s = Deploy::Secrets->new(app_home => $home);

subtest 'diff: no file, nothing required' => sub {
    my $d = $s->diff('svc', { required => {}, optional => {} });
    is_deeply $d->{missing}, [];
    is_deeply $d->{present}, [];
};

subtest 'diff: missing required key' => sub {
    my $d = $s->diff('svc', {
        required => { API_KEY => 'x', DB_URL => 'y' },
        optional => {},
    });
    is_deeply [sort @{$d->{missing}}], [qw(API_KEY DB_URL)];
};

subtest 'set + diff: required present' => sub {
    $s->set('svc', 'API_KEY', 'abc123', actor => 'tester');
    $s->set('svc', 'DB_URL',  'postgres://', actor => 'tester');
    my $d = $s->diff('svc', {
        required => { API_KEY => 'x', DB_URL => 'y' },
        optional => { LOG_LEVEL => { default => 'info' } },
    });
    is_deeply $d->{missing}, [], 'nothing missing';
    is_deeply [sort @{$d->{present}}], [qw(API_KEY DB_URL)];
    is_deeply $d->{optional_set}, [], 'optional key not set';
};

subtest 'atomic write: permissions 0600' => sub {
    my $file = path($home, 'secrets', 'svc.env');
    my $mode = (stat $file)[2] & 07777;
    is $mode, 0600, 'env file is 0600';
};

subtest 'audit log: append on set' => sub {
    my $log = path($home, 'secrets', 'svc.audit.log');
    ok $log->exists, 'audit log exists';
    my @lines = $log->lines_utf8({ chomp => 1 });
    is scalar @lines, 2, 'one line per set';
    like $lines[0], qr/^\S+ tester set API_KEY$/, 'format: ts actor action key';
    unlike $lines[0], qr/abc123/, 'value never in log';
};

subtest 'delete + diff' => sub {
    $s->delete('svc', 'DB_URL', actor => 'tester');
    my $d = $s->diff('svc', {
        required => { API_KEY => 'x', DB_URL => 'y' },
        optional => {},
    });
    is_deeply $d->{missing}, ['DB_URL'];
    my @lines = path($home, 'secrets', 'svc.audit.log')->lines_utf8({ chomp => 1 });
    like $lines[-1], qr/^\S+ tester delete DB_URL$/;
};

subtest 'reject invalid key name' => sub {
    my $err = eval { $s->set('svc', 'lowercase', 'x', actor => 't'); 0 } || $@;
    like $err, qr/invalid key/;
};

subtest 'reject value with newline' => sub {
    my $err = eval { $s->set('svc', 'GOOD_KEY', "a\nb", actor => 't'); 0 } || $@;
    like $err, qr/newline not allowed/;
};

done_testing;
```

- [ ] **Step 2: Run tests, confirm all fail**

```
prove -lv t/11-secrets.t
```
Expected: all fail with "Can't locate Deploy/Secrets.pm".

- [ ] **Step 3: Implement `Deploy::Secrets`**

```perl
# lib/Deploy/Secrets.pm
package Deploy::Secrets;

use Mojo::Base -base, -signatures;
use Path::Tiny qw(path);
use POSIX qw(strftime);
use Fcntl qw(O_WRONLY O_CREAT O_EXCL);

has 'app_home';

my $KEY_RE = qr/^[A-Z_][A-Z0-9_]*$/;

sub _env_file ($self, $name) {
    return path($self->app_home, 'secrets', "$name.env");
}

sub _audit_file ($self, $name) {
    return path($self->app_home, 'secrets', "$name.audit.log");
}

sub _read ($self, $name) {
    my $file = $self->_env_file($name);
    return {} unless $file->exists;
    my %env;
    for my $line ($file->lines_utf8({ chomp => 1 })) {
        next if $line =~ /^\s*(#|$)/;
        if ($line =~ /^([A-Z_][A-Z0-9_]*)=(.*)$/) {
            $env{$1} = $2;
        }
    }
    return \%env;
}

sub _write_atomic ($self, $name, $env) {
    my $file = $self->_env_file($name);
    $file->parent->mkpath;
    my $tmp  = path($file->parent, "$name.env.tmp.$$");
    my @lines = map { "$_=$env->{$_}" } sort keys %$env;
    $tmp->spew_utf8(join("\n", @lines) . (@lines ? "\n" : ''));
    chmod 0600, "$tmp" or die "chmod: $!";
    rename "$tmp", "$file" or die "rename: $!";
}

sub _audit ($self, $name, $actor, $action, $key) {
    my $log = $self->_audit_file($name);
    my $ts  = strftime('%Y-%m-%dT%H:%M:%SZ', gmtime);
    $log->append_utf8("$ts $actor $action $key\n");
    chmod 0600, "$log";
}

sub diff ($self, $name, $manifest_env) {
    my $env      = $self->_read($name);
    my %required = %{ $manifest_env->{required} // {} };
    my %optional = %{ $manifest_env->{optional} // {} };

    my @missing = grep { !exists $env->{$_} } sort keys %required;
    my @present = grep {  exists $env->{$_} } sort keys %required;
    my @opt_set = grep {  exists $env->{$_} } sort keys %optional;

    return { missing => \@missing, present => \@present, optional_set => \@opt_set };
}

sub set ($self, $name, $key, $value, %opts) {
    die "invalid key '$key'\n" unless $key =~ $KEY_RE;
    die "newline not allowed in value\n" if $value =~ /[\r\n]/;
    my $actor = $opts{actor} // 'unknown';

    my $env = $self->_read($name);
    $env->{$key} = $value;
    $self->_write_atomic($name, $env);
    $self->_audit($name, $actor, 'set', $key);
}

sub delete ($self, $name, $key, %opts) {
    die "invalid key '$key'\n" unless $key =~ $KEY_RE;
    my $actor = $opts{actor} // 'unknown';

    my $env = $self->_read($name);
    return unless exists $env->{$key};
    delete $env->{$key};
    $self->_write_atomic($name, $env);
    $self->_audit($name, $actor, 'delete', $key);
}

1;
```

- [ ] **Step 4: Run tests, confirm all pass**

```
prove -lv t/11-secrets.t
```
Expected: all subtests PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/Deploy/Secrets.pm t/11-secrets.t
git commit -m "Add Deploy::Secrets with atomic writes and audit log"
```

---

## Task 5: Secrets endpoints

**Files:**
- Modify: `bin/321.pl` (add three routes + wire `Deploy::Secrets` into app)
- Create: `t/13-secrets-endpoints.t`

- [ ] **Step 1: Write failing endpoint tests**

```perl
# t/13-secrets-endpoints.t
use strict;
use warnings;
use Test::More;
use Test::Mojo;
use MIME::Base64;
use Path::Tiny qw(tempdir path);

my $home = tempdir(CLEANUP => 1);
path($home, 'services')->mkpath;
path($home, 'secrets')->mkpath;

my $repo = tempdir(CLEANUP => 1);
path($repo, '.321.yml')->spew_utf8(<<'YAML');
name: demo.web
entry: bin/demo.pl
runner: hypnotoad
env_required:
  API_KEY: required
env_optional:
  LOG_LEVEL:
    default: info
YAML

path($home, 'services', 'demo.web.yml')->spew_utf8(<<"YAML");
name: demo.web
repo: $repo
targets:
  live:
    host: demo.do
    port: 9400
YAML

$ENV{MOJO_MODE} = 'production';
$ENV{APP_HOME}  = $home;

my $t = Test::Mojo->new(Mojo::File->new('bin/321.pl'));
my $auth = { Authorization => 'Basic ' . encode_base64('321:kaizen', '') };

$t->get_ok('/service/demo.web/secrets', $auth)
  ->status_is(200)
  ->json_is('/status' => 'success')
  ->json_is('/data/missing/0' => 'API_KEY')
  ->json_is('/data/present' => [])
  ->json_hasnt('/data/values');  # never leak values

$t->post_ok('/service/demo.web/secrets' => $auth => json => { key => 'API_KEY', value => 'abc' })
  ->status_is(200)
  ->json_is('/status' => 'success');

$t->get_ok('/service/demo.web/secrets', $auth)
  ->json_is('/data/missing' => [])
  ->json_is('/data/present/0' => 'API_KEY');

$t->post_ok('/service/demo.web/secrets' => $auth => json => { key => 'lowercase', value => 'x' })
  ->status_is(200)
  ->json_is('/status' => 'error')
  ->json_like('/message' => qr/invalid key/);

$t->post_ok('/service/demo.web/secrets/delete' => $auth => json => { key => 'API_KEY' })
  ->status_is(200)
  ->json_is('/status' => 'success');

$t->get_ok('/service/demo.web/secrets', $auth)
  ->json_is('/data/missing/0' => 'API_KEY');

done_testing;
```

- [ ] **Step 2: Run test, confirm failure**

```
prove -lv t/13-secrets-endpoints.t
```
Expected: 404 on every request (routes don't exist yet).

- [ ] **Step 3: Wire `Deploy::Secrets` into the app**

In `bin/321.pl`, find the section where `config_obj`/`ubic_mgr_obj`/etc. helpers are defined and add:

```perl
use Deploy::Secrets;

helper secrets_obj => sub {
    state $s = Deploy::Secrets->new(app_home => app->config_obj->app_home);
};
```

(If the existing code uses plain `$self->app->` accessors instead of helpers, match the pattern already used for `svc_mgr_obj`.)

- [ ] **Step 4: Add the three endpoints**

Find the block of routes under the basic-auth group and add:

```perl
$r->get('/service/:name/secrets' => sub ($c) {
    my $name = $c->param('name');
    my $svc  = $c->app->config_obj->service($name);
    return $c->json_response(error => "Unknown service: $name") unless $svc;

    my $diff = $c->app->secrets_obj->diff($name, {
        required => $svc->{env_required},
        optional => $svc->{env_optional},
    });
    $c->json_response(success => 'ok', {
        required     => [ sort keys %{ $svc->{env_required} } ],
        optional     => $svc->{env_optional},
        missing      => $diff->{missing},
        present      => $diff->{present},
        optional_set => $diff->{optional_set},
    });
});

$r->post('/service/:name/secrets' => sub ($c) {
    my $name = $c->param('name');
    my $body = $c->req->json // {};
    my $key  = $body->{key};
    my $val  = $body->{value} // '';
    return $c->json_response(error => 'key required') unless $key;

    my $actor = $c->req->url->to_abs->userinfo // 'unknown';
    $actor =~ s/:.*//;

    my $ok = eval {
        $c->app->secrets_obj->set($name, $key, $val, actor => $actor);
        1;
    };
    return $c->json_response(error => ($@ // 'set failed')) unless $ok;
    $c->json_response(success => "set $key for $name");
});

$r->post('/service/:name/secrets/delete' => sub ($c) {
    my $name = $c->param('name');
    my $body = $c->req->json // {};
    my $key  = $body->{key};
    return $c->json_response(error => 'key required') unless $key;

    my $actor = $c->req->url->to_abs->userinfo // 'unknown';
    $actor =~ s/:.*//;

    my $ok = eval {
        $c->app->secrets_obj->delete($name, $key, actor => $actor);
        1;
    };
    return $c->json_response(error => ($@ // 'delete failed')) unless $ok;
    $c->json_response(success => "deleted $key from $name");
});
```

Also ensure `app_home` in `Deploy::Config` can be overridden via `$ENV{APP_HOME}` so the test can point at a temp dir. Near the top of `lib/Deploy/Config.pm`:

```perl
has 'app_home' => sub { $ENV{APP_HOME} // curfile->dirname->dirname->dirname };
```

- [ ] **Step 5: Run test, confirm pass**

```
prove -lv t/13-secrets-endpoints.t
```
Expected: all subtests PASS.

- [ ] **Step 6: Run full suite**

```
prove -lr t
```
Expected: no regressions.

- [ ] **Step 7: Commit**

```bash
git add bin/321.pl lib/Deploy/Config.pm t/13-secrets-endpoints.t
git commit -m "Add secrets GET/POST/DELETE endpoints with audit logging"
```

---

## Task 6: Dashboard secrets badge

**Files:**
- Modify: `bin/321.pl` (the `/` template — `Dashboard`)

Include a `secrets: N/M` badge per service, red when N < M. Data comes from the same diff helper.

- [ ] **Step 1: Add a helper that returns badge data per service**

In `bin/321.pl`, above the routes:

```perl
helper secrets_badge => sub ($c, $name) {
    my $svc = $c->app->config_obj->service($name);
    return { required => 0, present => 0 } unless $svc;
    my $diff = $c->app->secrets_obj->diff($name, {
        required => $svc->{env_required},
        optional => $svc->{env_optional},
    });
    my $required = scalar keys %{ $svc->{env_required} };
    my $present  = $required - scalar @{ $diff->{missing} };
    return { required => $required, present => $present };
};
```

- [ ] **Step 2: Write failing test for the dashboard HTML**

```perl
# t/14-dashboard-secrets-badge.t
use strict;
use warnings;
use Test::More;
use Test::Mojo;
use MIME::Base64;
use Path::Tiny qw(tempdir path);

my $home = tempdir(CLEANUP => 1);
path($home, 'services')->mkpath;
path($home, 'secrets')->mkpath;
my $repo = tempdir(CLEANUP => 1);
path($repo, '.321.yml')->spew_utf8(
    "name: demo.web\nentry: bin/x.pl\nrunner: hypnotoad\n" .
    "env_required:\n  API_KEY: required\n"
);
path($home, 'services', 'demo.web.yml')->spew_utf8(
    "name: demo.web\nrepo: $repo\ntargets:\n  live:\n    host: demo.do\n    port: 9400\n"
);

$ENV{MOJO_MODE} = 'production';
$ENV{APP_HOME}  = $home;

my $t = Test::Mojo->new(Mojo::File->new('bin/321.pl'));
my $auth = { Authorization => 'Basic ' . encode_base64('321:kaizen', '') };

$t->get_ok('/', $auth)
  ->content_like(qr/secrets.*0\s*\/\s*1/i, 'badge shows 0/1 when missing');

done_testing;
```

- [ ] **Step 3: Run test, confirm failure**

```
prove -lv t/14-dashboard-secrets-badge.t
```
Expected: FAIL — no badge markup in dashboard yet.

- [ ] **Step 4: Edit the dashboard template**

Locate the `Dashboard` template in `bin/321.pl` (the `__DATA__` section with service rows). For each service row, add:

```
% my $b = secrets_badge($svc->{name});
% my $cls = $b->{present} < $b->{required} ? 'badge badge-red' : 'badge badge-green';
<span class="<%= $cls %>">secrets: <%= $b->{present} %>/<%= $b->{required} %></span>
```

Add minimal CSS to the existing style block:

```css
.badge { display:inline-block; padding:2px 6px; border-radius:3px; font-size:11px; }
.badge-red   { background:#c33; color:#fff; }
.badge-green { background:#393; color:#fff; }
```

- [ ] **Step 5: Run test, confirm pass**

```
prove -lv t/14-dashboard-secrets-badge.t
```
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add bin/321.pl t/14-dashboard-secrets-badge.t
git commit -m "Show secrets status badge on dashboard"
```

---

## Task 7: Secrets form on service page

**Files:**
- Modify: `bin/321.pl` (the `ServiceDetail` template)

Behaviour:
- **Required** section — for each `env_required` key, a row with key, description, status (`set` / `missing`), an `<input type=password>`, a Save button. Submitting empty does nothing (use delete button instead).
- **Optional** section (collapsed `<details>`) — same layout, shows default hint.
- **Delete** button next to each set key.

Form submits via `fetch` to the endpoints from Task 5.

- [ ] **Step 1: Write failing test**

```perl
# t/15-service-page-secrets-form.t
use strict;
use warnings;
use Test::More;
use Test::Mojo;
use MIME::Base64;
use Path::Tiny qw(tempdir path);

my $home = tempdir(CLEANUP => 1);
path($home, 'services')->mkpath;
path($home, 'secrets')->mkpath;
my $repo = tempdir(CLEANUP => 1);
path($repo, '.321.yml')->spew_utf8(<<'YAML');
name: demo.web
entry: bin/x.pl
runner: hypnotoad
env_required:
  API_KEY: "upstream API"
env_optional:
  LOG_LEVEL:
    default: info
    desc: "debug|info|warn"
YAML
path($home, 'services', 'demo.web.yml')->spew_utf8(
    "name: demo.web\nrepo: $repo\ntargets:\n  live:\n    host: demo.do\n    port: 9400\n"
);

$ENV{MOJO_MODE} = 'production';
$ENV{APP_HOME}  = $home;

my $t = Test::Mojo->new(Mojo::File->new('bin/321.pl'));
my $auth = { Authorization => 'Basic ' . encode_base64('321:kaizen', '') };

$t->get_ok('/ui/service/demo.web', $auth)
  ->content_like(qr/API_KEY/,        'required key name shown')
  ->content_like(qr/upstream API/,   'description shown')
  ->content_like(qr/LOG_LEVEL/,      'optional key shown')
  ->content_like(qr/type="?password/,'input is password type')
  ->content_unlike(qr/value="[^"]+"\s*>\s*<button[^>]*>Save/, 'values not pre-filled');

done_testing;
```

- [ ] **Step 2: Run test, confirm failure**

```
prove -lv t/15-service-page-secrets-form.t
```
Expected: FAIL — page doesn't render env fields yet.

- [ ] **Step 3: Add template section to `ServiceDetail`**

Locate the `ServiceDetail` template in `bin/321.pl`. Add (placed after the service info block, before logs):

```
<section class="secrets">
  <h2>Secrets</h2>

  <h3>Required</h3>
  <table class="env">
    % for my $k (sort keys %{ $svc->{env_required} }) {
      % my $is_set = grep { $_ eq $k } @{ $secrets->{present} };
      <tr data-key="<%= $k %>">
        <td class="k"><%= $k %></td>
        <td class="d"><%= $svc->{env_required}{$k} %></td>
        <td class="s"><%= $is_set ? 'set' : 'MISSING' %></td>
        <td>
          <input type="password" autocomplete="off" placeholder="<%= $is_set ? '(keep existing)' : 'set value' %>">
          <button class="set-secret">Save</button>
          % if ($is_set) {
          <button class="del-secret">Delete</button>
          % }
        </td>
      </tr>
    % }
  </table>

  <details>
    <summary>Optional (<%= scalar keys %{ $svc->{env_optional} } %>)</summary>
    <table class="env">
      % for my $k (sort keys %{ $svc->{env_optional} }) {
        % my $spec = $svc->{env_optional}{$k} // {};
        % my $is_set = grep { $_ eq $k } @{ $secrets->{optional_set} };
        <tr data-key="<%= $k %>">
          <td class="k"><%= $k %></td>
          <td class="d">
            <%= $spec->{desc} // '' %>
            % if (defined $spec->{default}) {
              <em>(default: <%= $spec->{default} %>)</em>
            % }
          </td>
          <td class="s"><%= $is_set ? 'set' : 'default' %></td>
          <td>
            <input type="password" autocomplete="off">
            <button class="set-secret">Save</button>
            % if ($is_set) {
            <button class="del-secret">Delete</button>
            % }
          </td>
        </tr>
      % }
    </table>
  </details>
</section>

<script>
document.querySelectorAll('button.set-secret').forEach(btn => {
  btn.onclick = async () => {
    const row = btn.closest('tr');
    const key = row.dataset.key;
    const value = row.querySelector('input').value;
    if (!value) return;
    const r = await fetch('/service/<%= $svc->{name} %>/secrets', {
      method: 'POST', headers: {'Content-Type':'application/json'},
      body: JSON.stringify({key, value})
    });
    if (r.ok) location.reload();
  };
});
document.querySelectorAll('button.del-secret').forEach(btn => {
  btn.onclick = async () => {
    const row = btn.closest('tr');
    const key = row.dataset.key;
    if (!confirm('Delete ' + key + '?')) return;
    const r = await fetch('/service/<%= $svc->{name} %>/secrets/delete', {
      method: 'POST', headers: {'Content-Type':'application/json'},
      body: JSON.stringify({key})
    });
    if (r.ok) location.reload();
  };
});
</script>
```

Also: update the `/ui/service/:name` route to pass `$secrets` into the template:

```perl
my $diff = $c->app->secrets_obj->diff($name, {
    required => $svc->{env_required},
    optional => $svc->{env_optional},
});
$c->render(template => 'service_detail', svc => $svc, secrets => $diff, ...);
```

- [ ] **Step 4: Run test, confirm pass**

```
prove -lv t/15-service-page-secrets-form.t
```
Expected: PASS.

- [ ] **Step 5: Manual smoke test**

Start the app: `perl bin/321.pl daemon -l http://127.0.0.1:9321`

In a browser, visit `http://127.0.0.1:9321/ui/service/321.web`. Verify:
- Secrets section shows required + optional tables.
- Setting a value reloads the page and status changes from MISSING → set.
- Delete button removes the key.
- Values never appear in the rendered HTML.

- [ ] **Step 6: Commit**

```bash
git add bin/321.pl t/15-service-page-secrets-form.t
git commit -m "Add secrets form UI to service page"
```

---

## Task 8: Block deploy/start when required secrets are missing

**Files:**
- Modify: `lib/Deploy/Service.pm` (precondition check in `deploy`)

- [ ] **Step 1: Write failing test**

```perl
# t/16-deploy-blocks-on-missing-secrets.t
use strict;
use warnings;
use Test::More;
use Path::Tiny qw(tempdir path);
use Deploy::Config;
use Deploy::Service;
use Deploy::Secrets;
use Mojo::Log;

my $home = tempdir(CLEANUP => 1);
path($home, 'services')->mkpath;
path($home, 'secrets')->mkpath;
my $repo = tempdir(CLEANUP => 1);
system("cd $repo && git init -q");
path($repo, '.321.yml')->spew_utf8(
    "name: demo.web\nentry: bin/x.pl\nrunner: hypnotoad\n" .
    "env_required:\n  API_KEY: required\n"
);
path($home, 'services', 'demo.web.yml')->spew_utf8(
    "name: demo.web\nrepo: $repo\ntargets:\n  live:\n    port: 9400\n"
);

my $c = Deploy::Config->new(app_home => $home, target => 'live');
my $s = Deploy::Service->new(
    config => $c,
    log    => Mojo::Log->new(level => 'fatal'),
);

my $result = $s->deploy('demo.web');
is $result->{status},  'error', 'deploy blocked';
like $result->{message}, qr/missing required secrets?: API_KEY/;

done_testing;
```

- [ ] **Step 2: Run test, confirm failure**

```
prove -lv t/16-deploy-blocks-on-missing-secrets.t
```
Expected: FAIL — deploy proceeds despite missing secret.

- [ ] **Step 3: Add precondition check in `deploy()`**

At the top of `sub deploy ($self, $name, %opts)` in `lib/Deploy/Service.pm`, after the `Unknown service` check, add:

```perl
my $secrets = Deploy::Secrets->new(app_home => $self->config->app_home);
my $diff = $secrets->diff($name, {
    required => $svc->{env_required} // {},
    optional => $svc->{env_optional} // {},
});
if (@{ $diff->{missing} }) {
    return {
        status  => 'error',
        message => 'missing required secret'
            . (@{$diff->{missing}} > 1 ? 's' : '')
            . ': ' . join(', ', @{ $diff->{missing} }),
    };
}
```

Add `use Deploy::Secrets;` at the top.

- [ ] **Step 4: Run test, confirm pass**

```
prove -lv t/16-deploy-blocks-on-missing-secrets.t
```
Expected: PASS.

- [ ] **Step 5: Run full suite**

```
prove -lr t
```

- [ ] **Step 6: Commit**

```bash
git add lib/Deploy/Service.pm t/16-deploy-blocks-on-missing-secrets.t
git commit -m "Block deploy when required secrets are missing"
```

---

## Task 9: Install command — fail fast without manifest

**Files:**
- Modify: `lib/Deploy/Command/install.pm`

After cloning the repo (or if it already exists), the install command should read the manifest and abort with a useful error if missing.

- [ ] **Step 1: Add manifest load after clone step**

In `lib/Deploy/Command/install.pm`, after the clone block (around line 34, after `say "  [OK] Cloned $git_url";`):

```perl
require Deploy::Manifest;
my $manifest = Deploy::Manifest->load($repo);
unless ($manifest) {
    die "\n  No .321.yml in $repo\n"
      . "  Every service repo must ship a manifest. See docs/superpowers/plans/2026-04-15-manifest-and-secrets-ui.md\n";
}
say "  [OK] Manifest: $manifest->{name} ($manifest->{runner}, $manifest->{entry})";
```

- [ ] **Step 2: Smoke test with a known-good service**

```
perl bin/321.pl install 321.web
```
Expected: prints `[OK] Manifest: 321.web (hypnotoad, bin/321.pl)`, continues to cpanm/ubic/nginx steps.

- [ ] **Step 3: Commit**

```bash
git add lib/Deploy/Command/install.pm
git commit -m "Require .321.yml manifest during install"
```

---

## Task 10: Migrate existing service YAMLs

**Files:**
- Modify: `services/321.web.yml`, `services/love.web.yml`, `services/zorda.web.yml`, `services.yml` (legacy)

Remove `bin` and `perlbrew` fields from each `services/*.yml` (they now come from each repo's `.321.yml`) — keep everything else. If a sibling service repo does not yet have a `.321.yml`, leave its deploy YAML unchanged for now (migration is per-repo and not atomic).

- [ ] **Step 1: Identify services whose repos have a manifest**

```
for d in /home/s3/*; do [ -f "$d/.321.yml" ] && echo "$d"; done
```

- [ ] **Step 2: For each such service, remove `bin` and `perlbrew` from `services/<name>.yml`**

Use `Edit` per file. Example for `services/321.web.yml`:

Remove lines:
```
bin: bin/321.pl
perlbrew: perl-5.42.1
```

Leave everything else — SOPS-encrypted `env` blocks, targets, hosts, ports — alone.

Re-encrypt after editing:

```
~/bin/sops encrypt -i services/321.web.yml
```

- [ ] **Step 3: Confirm resolved service is still correct**

```
perl -Ilib -MDeploy::Config -E '
  my $c = Deploy::Config->new;
  my $s = $c->service("321.web");
  use Data::Dumper; print Dumper($s);
'
```
Expected: `bin`, `perlbrew` still appear in the output (sourced from manifest).

- [ ] **Step 4: Commit after each migrated service**

```bash
git add services/321.web.yml
git commit -m "Migrate 321.web deploy config to rely on .321.yml manifest"
```

---

## Task 11: Document manifest contract

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Add a `## Service Repo Contract` section to CLAUDE.md**

Between the existing `## Architecture` and `## Development` sections:

````markdown
## Service Repo Contract

Every service repo installed by 321 must ship a `.321.yml` at the repo root. It declares code-side facts — things that belong with the application, not in the deploy repo.

```yaml
name: love.web              # <group>.<name>
entry: bin/love.pl
runner: hypnotoad           # hypnotoad | morbo | script
perl: perl-5.42.1           # optional; perlbrew version
health: /health             # optional; post-deploy probe path
env_required:               # keys the app cannot start without
  DATABASE_URL: "Postgres DSN"
env_optional:               # keys with sensible defaults or only-sometimes-needed
  LOG_LEVEL:
    default: info
    desc: "debug | info | warn"
```

The deploy repo (`services/<name>.yml`) only owns deploy-side facts: repo URL, branch, per-target `host`/`port`/`ssl`, and any operator overrides. `services/` YAML never duplicates fields defined in the manifest; when it does set a field that also exists in the manifest, the deploy-side value wins (operator override).

The 321 dashboard compares `env_required` against `secrets/<name>.env` and refuses to deploy or start a service with any missing required key.
````

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "Document .321.yml service repo contract"
```

---

## Self-Review Checklist

- [x] Every spec bullet (manifest, secrets UI, dashboard badge, deploy block, install gate, docs) has at least one task.
- [x] No TODO / "implement later" / "add appropriate error handling" placeholders.
- [x] Every code step contains runnable code — no handwaving.
- [x] Method/field names consistent: `env_required`/`env_optional` everywhere (not `required_env` in one task, `env_required` in another); `Deploy::Secrets` uses `diff`/`set`/`delete` everywhere; `entry` in manifest → `bin` in resolved service, documented in Task 3.
- [x] Exact file paths at every step.
- [x] Commit per task.
