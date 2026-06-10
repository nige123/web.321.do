use strict;
use warnings;
use Test::More;
use Deploy::Command::go;

# `321 go` must verify the target is reachable BEFORE deciding install vs
# deploy. A timed-out / refused SSH returns no usable output, which must not
# be mistaken for "repo absent" - that would wrongly clone over a live
# install. _reachable($transport) probes with an echo token.

# Minimal fake transport: returns whatever ->run was told to.
package FakeTransport {
    sub new { my ($c, %a) = @_; bless { %a }, $c }
    sub run { my $self = shift; return $self->{reply} }
}

my $cmd = Deploy::Command::go->new;

subtest 'reachable when the probe token echoes back' => sub {
    my $t = FakeTransport->new(reply => { ok => 1, output => "321-reachable\n", exit_code => 0 });
    ok $cmd->_reachable($t), 'token present → reachable';
};

subtest 'unreachable on SSH timeout (empty output, exit -1)' => sub {
    my $t = FakeTransport->new(reply => { ok => 0, output => "Error: Command timed out\n", exit_code => -1 });
    ok !$cmd->_reachable($t), 'timeout → not reachable';
};

subtest 'unreachable on empty output (connection refused)' => sub {
    my $t = FakeTransport->new(reply => { ok => 0, output => "", exit_code => 255 });
    ok !$cmd->_reachable($t), 'no token → not reachable';
};

subtest 'undef output is handled' => sub {
    my $t = FakeTransport->new(reply => { ok => 0 });
    ok !$cmd->_reachable($t), 'undef output → not reachable';
};

done_testing;
