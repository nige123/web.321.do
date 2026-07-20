use strict;
use warnings;
use Test::More;
use Path::Tiny qw(tempdir path);
use Deploy::Config;

# Return the tempdir OBJECT (not a string) so CLEANUP doesn't delete the dir
# before Config scans it; the caller holds it for the subtest's lifetime.
sub scan_with {
    my ($yaml) = @_;
    my $scan = tempdir(CLEANUP => 1);
    my $repo = path($scan, 'tui.123.do');
    $repo->mkpath;
    path($repo, '321.yml')->spew_utf8($yaml);
    return $scan;
}

subtest 'gobin block is surfaced verbatim on the resolved service' => sub {
    my $scan = scan_with(<<'YAML');
name: 123.cli
entry: bin/noop
runner: script
gobin:
  name: 123
  main: .
  version_var: main.version
  s3:
    bucket: 123do-releases
    prefix: bin/123
  sign_key: gobin_signing_key
  retain: 5
dev:
  host: cli.dev
  port: 1
YAML
    my $cfg = Deploy::Config->new(app_home => "$scan", scan_dir => $scan, target => 'dev');
    my $svc = $cfg->service('123.cli');
    is $svc->{gobin}{name},           '123',            'name';
    is $svc->{gobin}{s3}{bucket},     '123do-releases', 's3.bucket';
    is $svc->{gobin}{version_var},    'main.version',   'version_var';
    is $svc->{gobin}{retain},         5,                'retain';
};

subtest 'no gobin key when the manifest omits the block' => sub {
    my $scan = scan_with(<<'YAML');
name: plain.web
entry: bin/app.pl
runner: hypnotoad
dev:
  host: plain.dev
  port: 2
YAML
    my $cfg = Deploy::Config->new(app_home => "$scan", scan_dir => $scan, target => 'dev');
    ok !exists $cfg->service('plain.web')->{gobin}, 'gobin absent';
};

done_testing;
