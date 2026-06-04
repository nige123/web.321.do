use strict;
use warnings;
use Test::More;
use Path::Tiny qw(tempdir path);
use Deploy::Config;
use Deploy::SSH;

# `321 do <service?> <target> <subcommand> [args...]` runs an arbitrary
# Mojolicious subcommand of a service's app in that service's real runtime
# environment, on the chosen target.

sub make_cfg {
    my $home = tempdir(CLEANUP => 1);
    my $scan = tempdir(CLEANUP => 1);
    my $repo = path($scan, 'app.petals');
    $repo->mkpath;
    path($repo, '321.yml')->spew_utf8(<<'YAML');
name: petals.web
entry: bin/app.pl
runner: hypnotoad
perl: perl-5.42.1
dev:
  host: petals.dev
  port: 8700
  runner: morbo
live:
  host: petals.co
  port: 8700
  runner: hypnotoad
  ssh: ubuntu@petals.co
  ssh_key: ~/.ssh/petals.pem
  env:
    MOJO_MODE: production
    MOJO_CONFIG: /home/ubuntu/app.petals/conf/production.conf
YAML
    return (Deploy::Config->new(app_home => "$home", scan_dir => "$scan", target => 'dev'),
            "$home", "$scan", $home, $scan);
}

sub make_app {
    my ($cfg) = @_;
    require Mojolicious;
    my $app = Mojolicious->new;
    $app->attr(config_obj => sub { $cfg });
    return $app;
}

# Mojolicious::Command holds `app` weakly, so the app would be GC'd if we
# didn't keep a strong ref of our own. Stash it.
my @keep_apps;
sub make_cmd {
    my ($cfg) = @_;
    require Deploy::Command::do;
    my $app = make_app($cfg);
    push @keep_apps, $app;
    return Deploy::Command::do->new(app => $app);
}

subtest 'parse_args: target + subcommand, service inferred' => sub {
    my ($cfg, @keep) = make_cfg();
    my $cmd = make_cmd($cfg);
    my $p = $cmd->parse_args('live', 'create_admin', 'nige@123.do');
    is $p->{service}, undef,          'no explicit service';
    is $p->{target},  'live',         'target picked out';
    is $p->{subcmd},  'create_admin', 'subcommand';
    is_deeply $p->{args}, ['nige@123.do'], 'remaining args';
};

subtest 'parse_args: explicit service before target' => sub {
    my ($cfg, @keep) = make_cfg();
    my $cmd = make_cmd($cfg);
    my $p = $cmd->parse_args('petals.web', 'live', 'create_admin', 'x');
    is $p->{service}, 'petals.web', 'explicit service';
    is $p->{target},  'live',       'target';
    is $p->{subcmd},  'create_admin','subcommand';
    is_deeply $p->{args}, ['x'],     'args';
};

subtest 'parse_args: no target token defaults to dev' => sub {
    my ($cfg, @keep) = make_cfg();
    my $cmd = make_cmd($cfg);
    my $p = $cmd->parse_args('create_admin', 'a@b');
    is $p->{target}, 'dev',          'defaults to dev';
    is $p->{subcmd}, 'create_admin', 'first token is the subcommand';
    is_deeply $p->{args}, ['a@b'],   'rest are its args';
};

subtest 'parse_args: missing subcommand dies' => sub {
    my ($cfg, @keep) = make_cfg();
    my $cmd = make_cmd($cfg);
    eval { $cmd->parse_args('live') };
    like $@, qr/subcommand/i, 'a bare target is rejected';
};

subtest 'build_command reproduces the runtime env and invokes the subcommand' => sub {
    my ($cfg, @keep) = make_cfg();
    $cfg->target('live');
    my $svc = $cfg->service('petals.web');
    my $cmd = make_cmd($cfg);

    my $c = $cmd->build_command($svc, 'create_admin', ['nige@123.do']);

    like $c, qr/perlbrew exec --with perl-5\.42\.1/, 'selects the service perl';
    like $c, qr/MOJO_MODE='production'/,             'passes MOJO_MODE';
    like $c, qr{MOJO_CONFIG='/home/ubuntu/app\.petals/conf/production\.conf'},
        'passes the live MOJO_CONFIG';
    like $c, qr{PERL5LIB='[^']*/app\.petals/local/lib/perl5'}, 'sets repo-local PERL5LIB';
    like $c, qr/perl -MConfig bin\/app\.pl create_admin 'nige\@123\.do'/,
        'runs the entry with the subcommand and quoted args';
    # Core Config is preloaded before the app script. Apps that unshift their
    # bundled local-lib subdirs onto @INC (a common app.pl pattern) can shadow
    # core Config.pm; the supervised daemon only dodges this because hypnotoad
    # loads Config early. Mirror that load order so subcommands resolve the same
    # modules the daemon does.
    like $c, qr/perl -MConfig /, 'preloads core Config ahead of the app';
    # env must come before the perl invocation
    ok index($c, 'MOJO_MODE') < index($c, 'perl -MConfig bin/app.pl'),
        'env precedes the perl invocation';
};

subtest 'build_command shell-quotes nasty args' => sub {
    my ($cfg, @keep) = make_cfg();
    $cfg->target('dev');
    my $svc = $cfg->service('petals.web');
    my $cmd = make_cmd($cfg);
    my $c = $cmd->build_command($svc, 'run', [q{a' ; rm -rf /}]);
    unlike $c, qr/; rm -rf \/ (?!')/, 'no unquoted injection';
    like   $c, qr/run 'a'\\''/, 'single quotes are escaped';
};

subtest 'SSH _ssh_exec_cmd allocates a TTY and sources perlbrew' => sub {
    my $ssh = Deploy::SSH->new(user => 'ubuntu', host => 'petals.co', key => '/k.pem');
    my $full = $ssh->_ssh_exec_cmd('/home/ubuntu/app.petals', 'perl bin/app.pl create_admin x');
    like $full, qr/ssh -t /,                        'requests a remote TTY (-t)';
    like $full, qr{-i /k\.pem},                     'uses the key';
    like $full, qr/ubuntu\@petals\.co/,             'targets user@host';
    like $full, qr{cd /home/ubuntu/app\.petals &&}, 'cds into the repo';
    like $full, qr/perlbrew\/etc\/bashrc/,          'sources perlbrew so the right perl is found';
    like $full, qr/create_admin x/,                 'carries the command';
};

done_testing;
