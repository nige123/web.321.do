# Copyright Nige Ltd. Author: Nigel Hamilton.
use strict;
use warnings;
use feature 'signatures';

BEGIN { $ENV{MOJO_MODE} ||= 'testing'; $ENV{MOJO_CONFIG} ||= 't/conf/test.conf'; }

use Test::Most;
use lib 'lib';
use Mojo::Log;
use F6::Email::Sender;

# Capture the HTML by overriding _send.
my %sent;
my $sender = F6::Email::Sender->new(log => Mojo::Log->new(level => 'fatal'), token => '');
{
    no warnings 'redefine';
    *F6::Email::Sender::_send = sub ($self, $to, $subject, $html, @rest) {
        %sent = (to => $to, subject => $subject, html => $html);
        return { ok => 1, delivery => 'log' };
    };
}

my $summary = {
    date => '2026-06-12',
    growth => {
        signups          => { value => 3, prev => 1, avg7 => 0.6, dir => 'up' },
        teams            => { value => 1, prev => 0, avg7 => 0.1, dir => 'up' },
        favsixes         => { value => 2, prev => 2, avg7 => 1.0, dir => 'flat' },
        tiles            => { value => 5, prev => 9, avg7 => 4.0, dir => 'down' },
        invites_sent     => { value => 0, prev => 0, avg7 => 0.0, dir => 'flat' },
        invites_accepted => { value => 0, prev => 0, avg7 => 0.0, dir => 'flat' },
    },
    engagement => {
        active_users => { value => 2, prev => 1, avg7 => 0.7, dir => 'up' },
        clicks       => { value => 2, prev => 1, avg7 => 0.7, dir => 'up' },
        submissions  => { value => 0, prev => 0, avg7 => 0.0, dir => 'flat' },
        busiest      => [ { title => 'Ops', handle => 'crew', n => 2 } ],
    },
    billing => {
        funnel => { free => 4, trialing => 1, active => 1, past_due => 0, canceled => 0, other => 0 },
        trials_started        => { value => 1, prev => 0, avg7 => 0.1, dir => 'up' },
        payments_received     => { value => 0, prev => 0, avg7 => 0.0, dir => 'flat' },
        billable_active_users => 1,
    },
};

my $res = $sender->send_daily_report('nige@123.do', $summary);
ok $res->{ok}, 'send returned ok';
is $sent{to}, 'nige@123.do', 'addressed to the owner';
like $sent{subject}, qr/FavSix daily/, 'subject branded';
like $sent{subject}, qr/3 signups/,    'headline numbers in subject';
unlike $sent{subject}, qr/\x{2014}/,   'no em-dash in subject';
like $sent{html}, qr/Growth/,          'growth section present';
like $sent{html}, qr/Engagement/,      'engagement section present';
like $sent{html}, qr/Revenue/,         'revenue section present';
like $sent{html}, qr/Ops/,             'busiest FavSix listed';
like $sent{html}, qr/favsix\.com/,     'branded _shell footer present';

done_testing;
