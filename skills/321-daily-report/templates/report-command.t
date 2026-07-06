use strict;
use warnings;
use feature 'signatures';

BEGIN { $ENV{MOJO_MODE} ||= 'testing'; $ENV{MOJO_CONFIG} ||= 't/conf/test.conf'; }

use Test::Most;
use lib 'lib';
use lib 't/lib';
use Test::F6 qw(test_mojo);
use F6::Command::report;

my $t  = test_mojo();
my $db = $t->app->db;

# Count sends without hitting the network: stub the email_sender helper.
my $sends = 0;
$t->app->helper(email_sender => sub ($c_or_app) {
    return Test::FakeSender->new(\$sends);
});

sub cmd (@args) {
    my $c = F6::Command::report->new(app => $t->app);
    return $c->run(@args);
}

subtest 'sends once, then is idempotent for the same date' => sub {
    cmd('2026-06-12', '--to=nige@123.do');
    is $sends, 1, 'one send';
    is $db->raw("SELECT count(*) AS n FROM daily_reports WHERE report_date='2026-06-12'")->hash->{n}, 1,
        'one audit row';

    cmd('2026-06-12', '--to=nige@123.do');
    is $sends, 1, 'second run for the same date does not resend';
};

subtest '--force resends and refreshes the audit row' => sub {
    cmd('2026-06-12', '--to=forced@example.com', '--force');
    is $sends, 2, 'forced resend';
    is $db->raw("SELECT recipient FROM daily_reports WHERE report_date='2026-06-12'")->hash->{recipient},
        'forced@example.com', 'audit row recipient refreshed by force';
};

subtest '--dry-run neither sends nor records' => sub {
    cmd('2026-06-11', '--to=nige@123.do', '--dry-run');
    is $sends, 2, 'no send on dry-run';
    is $db->raw("SELECT count(*) AS n FROM daily_reports WHERE report_date='2026-06-11'")->hash->{n}, 0,
        'no audit row on dry-run';
};

subtest 'empty recipient is inert' => sub {
    cmd('2026-06-10');   # no --to, test.conf has no daily_report_to
    is $sends, 2, 'nothing sent when no recipient configured';
    is $db->raw("SELECT count(*) AS n FROM daily_reports WHERE report_date='2026-06-10'")->hash->{n}, 0,
        'no audit row';
};

done_testing;

# --- a minimal fake sender ---------------------------------------------------
package Test::FakeSender;
sub new ($class, $counter) { return bless { counter => $counter }, $class }
sub send_daily_report ($self, $to, $summary) {
    ${ $self->{counter} }++;
    return { ok => 1, delivery => 'log' };
}
