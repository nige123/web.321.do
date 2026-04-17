use Mojo::Base -strict, -signatures;
use Test::More;

use Deploy::Transport;

# 1. Local target (no ssh field) returns Deploy::Local
{
    my $target = { host => 'localhost', port => 9001 };
    my $t = Deploy::Transport->for_target($target);
    isa_ok $t, 'Deploy::Local', 'no-ssh target returns Deploy::Local';
    ok !$t->perlbrew, 'no perlbrew set by default';
}

# 2. SSH target (has ssh + ssh_key) returns Deploy::SSH with correct user/host/key
{
    my $target = {
        host    => '321.do',
        port    => 9001,
        ssh     => 'deploy@321.do',
        ssh_key => '/home/s3/.ssh/id_ed25519',
    };
    my $t = Deploy::Transport->for_target($target);
    isa_ok $t, 'Deploy::SSH', 'ssh target returns Deploy::SSH';
    is $t->user, 'deploy',                    'user parsed from user@host';
    is $t->host, '321.do',                    'host parsed from user@host';
    is $t->key,  '/home/s3/.ssh/id_ed25519',  'ssh_key passed as key';
    ok !$t->perlbrew,                          'no perlbrew set by default';
}

# 3. SSH target with perlbrew option passes it through
{
    my $target = {
        ssh     => 'nigel@prod.321.do',
        ssh_key => '/home/nige/.ssh/deploy_key',
    };
    my $t = Deploy::Transport->for_target($target, perlbrew => 'perl-5.42.0');
    isa_ok $t, 'Deploy::SSH', 'ssh target with perlbrew returns Deploy::SSH';
    is $t->user,     'nigel',                    'user correct';
    is $t->host,     'prod.321.do',              'host correct';
    is $t->perlbrew, 'perl-5.42.0',              'perlbrew passed through to SSH';
}

# 4. Local target with perlbrew option passes it through
{
    my $target = { host => 'localhost', port => 9002 };
    my $t = Deploy::Transport->for_target($target, perlbrew => 'perl-5.42.0');
    isa_ok $t, 'Deploy::Local', 'local target with perlbrew returns Deploy::Local';
    is $t->perlbrew, 'perl-5.42.0', 'perlbrew passed through to Local';
}

done_testing;
