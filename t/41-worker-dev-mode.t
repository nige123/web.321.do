use strict;
use warnings;
use Test::More;
use Path::Tiny qw(tempdir path);
use Deploy::Config;

# Regression: workers used to inherit MOJO_MODE=production on every target
# because mode was inferred from runner ('script' for workers) instead of from
# the target name. The dev minion then connected to the live DB and died.

my $home = tempdir(CLEANUP => 1);
my $scan = tempdir(CLEANUP => 1);

my $repo = path($scan, 'app.favsix.com');
$repo->mkpath;
path($repo, '321.yml')->spew_utf8(<<'YAML');
name: favsix.web
entry: bin/favsix.pl
runner: hypnotoad
perl: perl-5.42.1

dev:
  host: favsix.com.dev
  port: 8400
  runner: morbo

live:
  host: favsix.com
  port: 8400
  runner: hypnotoad
  ssh: ubuntu@zorda.co

workers:
  minion:
    cmd: bin/minion-worker.pl
YAML

for my $case (
    { target => 'dev',  name => 'favsix.web',    expect => 'development' },
    { target => 'live', name => 'favsix.web',    expect => 'production'  },
    { target => 'dev',  name => 'favsix.minion', expect => 'development' },
    { target => 'live', name => 'favsix.minion', expect => 'production'  },
) {
    my $c = Deploy::Config->new(
        app_home => $home, scan_dir => "$scan", target => $case->{target},
    );
    my $svc = $c->service($case->{name});
    is $svc->{mode}, $case->{expect},
        "mode=$case->{expect} for $case->{name} on $case->{target}";
}

done_testing;
