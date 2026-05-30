use strict;
use warnings;
use Test::More;
use Path::Tiny qw(tempdir path);
use Deploy::Config;

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
