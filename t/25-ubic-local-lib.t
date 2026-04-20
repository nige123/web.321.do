use strict;
use warnings;
use Test::More;
use Path::Tiny qw(tempdir path);
use Deploy::Config;
use Deploy::Ubic;

my $home_obj = tempdir(CLEANUP => 1);
path($home_obj, 'secrets')->mkpath;
my $scan_obj = tempdir(CLEANUP => 1);

my $repo = path($scan_obj, 'web.demo.do');
$repo->mkpath;
path($repo, '321.yml')->spew_utf8(<<'YAML');
name: demo.web
entry: bin/app.pl
runner: hypnotoad
live:
  host: demo.do
  port: 9400
  runner: hypnotoad
YAML

my $cfg = Deploy::Config->new(app_home => "$home_obj", scan_dir => "$scan_obj", target => 'live');

# Generate writes to ~/ubic/service/<group>/<name>
my $u = Deploy::Ubic->new(config => $cfg);
my $gen = $u->generate('demo.web');

my $repo_str = "$repo";
my $content = path($gen->{path})->slurp_utf8;

like $content, qr{PERL5LIB=\\'\Q$repo_str\E/local/lib/perl5\\'},
    'PERL5LIB points at repo-local lib';
like $content, qr{PATH=\\'\Q$repo_str\E/local/bin:},
    'PATH prepends repo-local bin';
like $content, qr{hypnotoad -f \Q$repo_str\E/bin/app\.pl},
    'bin path intact';

# Parse-test: the rendered Perl must actually compile
my $ok = eval "package _tst; $content; 1";
ok $ok, 'generated ubic service file parses as valid Perl' or diag $@;

done_testing;
