# Worker lifecycle cascade

Date: 2026-05-30

## Problem

Workers declared under a service's `workers:` block in `321.yml` are expanded into independent ubic services named `<group>.<workerName>` (Config.pm:51). They share the parent repo but they are full ubic processes with their own pid, logs, and ubic file.

Today the lifecycle commands — `321 go`, `321 start`, `321 stop`, `321 restart` — only act on the named service. Bringing a service with a minion worker fully up or down requires two calls (one for the main, one for each worker). It is easy to forget the second call, leaving the main hot-restarted on new code while the worker continues to run the old code, or the main stopped while a worker keeps consuming jobs.

A "service unit" should behave like one unit for the operator. Naming the main should mean "everything that ships from this repo".

## Behavior

A unit = the main service + every entry in its manifest's `workers:` block.

| Command | Name resolves to main *with* workers | Name resolves to a worker directly |
|---|---|---|
| `321 go <main>` | Deploy main (existing flow: tests → git → cpanm → migrate → ubic restart → port check → `_ensure_serving`). If the main deploy did not error, `ubic restart` each worker via the same transport. Workers do not get their own git/cpanm — they share the repo the main just deployed. | Unchanged: ubic restart on that worker only. |
| `321 start <main>` | Start main (existing `_start_one`). If main came up (status is "running"), call `_start_one` for each worker in sorted worker-name order. | Unchanged: start that worker. |
| `321 stop <main>` | Stop each worker in *reverse* sorted worker-name order, then stop main. | Unchanged: stop that worker. |
| `321 restart <main>` | Restart main (existing flow). If the main restart succeeded, `ubic restart` each worker via the transport. | Unchanged. |

`321 install` is out of scope — it already regenerates ubic files for every worker via `321 generate`, and only one start happens at install time (the main); a subsequent `321 start <main>` will pick up workers via this new behavior.

`321 status` is out of scope.

### Ordering

- Start / go / restart: main first, then workers in sorted worker-name order. Workers can depend on the main being up (e.g. a minion talking to a DB the main wires up); the reverse is not true.
- Stop: workers first (reverse sorted worker-name order), then main. Lets in-flight jobs drain before the main process exits.

### Failure handling

- If the main step itself errors (deploy reports `error`, start does not produce a "running" status, stop fails), the worker pass is skipped — there is nothing useful to cascade to.
- If an individual worker step errors, log the failure and continue with the next worker. The overall command does not abort. Rationale: workers are independent processes; the user can investigate a stuck worker without rolling back the rest.
- Output: one line per worker step (success or failure) so the operator sees the full picture.

### Worker-only target

Naming a worker directly (`321 start 123.minion`) acts only on that worker. The cascade is opt-in via the main service name. Lets the operator cycle a stuck worker without disturbing the web tier.

## Implementation

One helper, four small command edits, no schema changes.

### `Deploy::Config::workers_of($name)`

New method. Returns an arrayref of worker service names (`<group>.<workerName>`) belonging to a main service, or `[]` for a worker or a main with no workers.

```perl
sub workers_of ($self, $name) {
    $self->_check_reload;
    my $manifest = $self->_services->{$name};
    return [] unless $manifest;
    return [] if exists $manifest->{_parent};        # this entry is a worker, not a main
    my $workers = $manifest->{workers} // {};
    my ($group) = split /\./, $name, 2;
    return [ map { "$group.$_" } sort keys %$workers ];
}
```

Sorted by worker name for deterministic ordering — the manifest's `workers:` is a hash, so there is no sorted worker-name order to preserve, and sorted is what the existing Config code already does (see Config.pm:53 `for my $worker_name (keys %$workers)` — which is unordered today; we are formalising to sorted). Reverse-stop iterates the reverse of this sorted list.

### `Deploy::Command::go::run`

After the existing main-service branch completes (after the `_ensure_serving` call at go.pm:65), check `config->workers_of($name)`. If non-empty and `$r->{status} ne 'error'`:

```perl
for my $worker (@{ $self->config->workers_of($name) }) {
    my $wr = $transport->run("ubic restart $worker");
    if ($wr->{ok}) {
        say "  [OK] worker $worker restarted";
    } else {
        say "  [FAIL] worker $worker — $wr->{output}";
    }
}
```

Placed only on the redeploy path. The install path (`$needs_install` branch) already brings the unit up cold; once installed, the next `321 go` will exercise the cascade on the redeploy path.

### `Deploy::Command::start::run`

After `_start_one($name, $target)`, if the main came up *and* it is a main with workers, iterate `workers_of` and call `_start_one($worker, $target)` for each. The existing `_start_one` already handles workers correctly: port check is gated on `$port`, and workers have no port (Config.pm:96).

"Main came up" = parse the same status check `_start_one` already does: `ubic status $name` returns `running (pid …)`. To avoid re-querying, factor `_start_one` to return a truthy "did it start" boolean and use that to gate the cascade.

### `Deploy::Command::stop::run`

Before stopping the main service, if name is a main with workers, iterate `reverse @{ workers_of($name) }` and run `ubic stop $worker` via the transport, reporting per-worker status the same way the main stop already reports.

### `Deploy::Command::restart::run`

After the main `$svc_mgr->restart($name)` returns `status => 'success'`, iterate `workers_of($name)` and `ubic restart` each via the transport, with one line of output per worker.

## Testing

Extend `t/27-service-lifecycle.t` (or add a new `t/40-worker-cascade.t`) using the existing tempdir + git + 321.yml fixture pattern. The fixture declares a manifest with a `workers:` block:

```yaml
name: demo.web
entry: bin/app.pl
runner: hypnotoad
workers:
  printer:
    cmd: bin/printer-worker.pl
live:
  host: demo.do
  port: 39400
  runner: hypnotoad
```

Tests:

1. **Config method**: `Config->workers_of('demo.web')` returns `['demo.printer']`; `workers_of('demo.printer')` returns `[]`; `workers_of('demo.web')` on a manifest with no `workers:` returns `[]`.
2. **Start cascade**: A `TestStart` subclass records each `ubic start` call. `321 start demo.web` records starts for `demo.web` then `demo.printer`.
3. **Start worker-only**: `321 start demo.printer` records a start for `demo.printer` and *not* `demo.web`.
4. **Stop cascade reverse order**: With two workers in the fixture (`printer` and `mailer`), `321 stop demo.web` records stops for `demo.mailer`, then `demo.printer`, then `demo.web`.
5. **Main failure short-circuits**: A `TestStart` that makes the main fail to come up does *not* record any worker starts.
6. **Worker failure does not abort cascade**: With two workers, if the first worker stop fails, the second worker stop and the main stop still run.

Existing tests in `t/27-service-lifecycle.t` (which use a manifest without `workers:`) should keep passing unchanged.

## Out of scope

- Changing `321 status` to roll up worker status under the main row.
- Changing `321 install` to start workers eagerly at install time.
- Parallel start/stop of workers.
- A `--no-workers` flag to opt out of the cascade — can be added later if a real use case appears; until then, naming a worker directly is the escape hatch.
