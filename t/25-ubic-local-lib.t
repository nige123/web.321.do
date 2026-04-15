use strict;
use warnings;
use Test::More;
use Path::Tiny qw(tempdir path);
use Deploy::Config;
use Deploy::Ubic;

my $home = tempdir(CLEANUP => 1);
path($home, 'services')->mkpath;
path($home, 'secrets')->mkpath;

my $repo = tempdir(CLEANUP => 1);

path($home, 'services', 'demo.web.yml')->spew_utf8(<<"YAML");
name: demo.web
repo: $repo
bin: bin/app.pl
targets:
  live:
    host: demo.do
    port: 9400
    runner: hypnotoad
YAML

my $cfg = Deploy::Config->new(app_home => $home, target => 'live');

# Render into a tempdir — we only want the file contents to inspect
path($repo, 'ubic', 'service', 'demo')->mkpath;
my $u = Deploy::Ubic->new(config => $cfg);
$u->generate('demo.web');

my $content = path($repo, 'ubic', 'service', 'demo', 'web')->slurp_utf8;

like $content, qr{PERL5LIB=\\'\Q$repo\E/local/lib/perl5\\'},
    'PERL5LIB points at repo-local lib';
like $content, qr{PATH=\\'\Q$repo\E/local/bin:},
    'PATH prepends repo-local bin';
like $content, qr{hypnotoad -f \Q$repo\E/bin/app\.pl},
    'bin path intact';

# Parse-test: the rendered Perl must actually compile
my $ok = eval "package _tst; $content; 1";
ok $ok, 'generated ubic service file parses as valid Perl' or diag $@;

done_testing;
