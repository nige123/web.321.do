# Copyright Nige Ltd. Author: Nigel Hamilton.
package F6::Model::Reporting;

#------------------------------------------------------------------------------
# Nigel Hamilton
#
# Filename:     Reporting.pm
# Description:  Platform-wide daily usage aggregation for the owner report.
#               daily_summary($date) returns growth / engagement / billing
#               metrics for a single Europe/London calendar day, each count
#               carrying a trend (value, prior day, 7-day average, direction).
#               Pure reads; the report command and any future dashboard share it.
#------------------------------------------------------------------------------

use Mojo::Base -base, -signatures;

has 'db';

#------------------------------------------------------------------------------
# daily_summary - the whole report for one London day (YYYY-MM-DD)
#------------------------------------------------------------------------------
sub daily_summary ($self, $report_date) {
    my @days = $self->_day_axis($report_date);
    return {
        date       => $report_date,
        growth     => $self->_growth($report_date, \@days),
        engagement => $self->_engagement($report_date, \@days),
        billing    => $self->_billing($report_date, \@days),
    };
}

#------------------------------------------------------------------------------
# _day_axis - the 8 ordered London date strings D-7 .. D (index 7 = D)
#------------------------------------------------------------------------------
sub _day_axis ($self, $report_date) {
    my $rows = $self->db->query('reporting/day_axis',
        { report_date => $report_date })->hashes->to_array;
    return map { $_->{day} } @$rows;
}

#------------------------------------------------------------------------------
# _pivot - [{metric,day,n}] -> { metric => { day => n } }
#------------------------------------------------------------------------------
sub _pivot ($self, $rows) {
    my %by;
    $by{ $_->{metric} }{ $_->{day} } = $_->{n} for @$rows;
    return \%by;
}

#------------------------------------------------------------------------------
# _trend - over the ordered day axis: { value, prev, avg7, dir }
#   value = D (last), prev = D-1, avg7 = mean of D-7..D-1 (7 days)
#------------------------------------------------------------------------------
sub _trend ($self, $days, $by_day) {
    my @c     = map { $by_day->{$_} // 0 } @$days;
    my $val   = $c[-1];
    my $prev  = $c[-2] // 0;                     # // 0 kept: axis could be length 1
    my @prior = @c[0 .. $#c - 1];                # every day before D
    my $sum   = 0; $sum += $_ for @prior;
    my $avg   = @prior ? sprintf('%.1f', $sum / scalar(@prior)) + 0 : 0;
    my $dir   = $val > $prev ? 'up' : $val < $prev ? 'down' : 'flat';
    return { value => $val + 0, prev => $prev + 0, avg7 => $avg, dir => $dir };
}

#------------------------------------------------------------------------------
# _growth / _engagement / _billing - one section each
#------------------------------------------------------------------------------
sub _growth ($self, $report_date, $days) {
    my $by = $self->_pivot($self->db->query('reporting/growth_series',
        { report_date => $report_date })->hashes->to_array);
    return {
        map { $_ => $self->_trend($days, $by->{$_} // {}) }
            qw(signups teams favsixes tiles invites_sent invites_accepted)
    };
}

sub _engagement ($self, $report_date, $days) {
    my $by = $self->_pivot($self->db->query('reporting/engagement_series',
        { report_date => $report_date })->hashes->to_array);
    my $busiest = $self->db->query('reporting/busiest',
        { report_date => $report_date })->hashes->to_array;
    $_->{n} += 0 for @$busiest;
    return {
        active_users => $self->_trend($days, $by->{active_users} // {}),
        clicks       => $self->_trend($days, $by->{clicks}       // {}),
        submissions  => $self->_trend($days, $by->{submissions}  // {}),
        busiest      => $busiest,
    };
}

sub _billing ($self, $report_date, $days) {
    my $funnel_rows = $self->db->query('reporting/billing_funnel')->hashes->to_array;
    my %f = map { $_->{billing_status} => $_->{n} } @$funnel_rows;
    my $total = 0; $total += $_->{n} for @$funnel_rows;
    my $known = ($f{free} // 0) + ($f{trialing} // 0) + ($f{active} // 0)
              + ($f{past_due} // 0) + ($f{canceled} // 0);
    my $by = $self->_pivot($self->db->query('reporting/billing_events_series',
        { report_date => $report_date })->hashes->to_array);
    my $billable = $self->db->query('reporting/billable_active',
        { report_date => $report_date })->hash->{n} // 0;
    return {
        funnel => {
            free     => ($f{free}     // 0) + 0,
            trialing => ($f{trialing} // 0) + 0,
            active   => ($f{active}   // 0) + 0,
            past_due => ($f{past_due} // 0) + 0,
            canceled => ($f{canceled} // 0) + 0,
            other    => ($total - $known) + 0,
        },
        trials_started        => $self->_trend($days, $by->{trials_started}    // {}),
        payments_received     => $self->_trend($days, $by->{payments_received} // {}),
        billable_active_users => $billable + 0,
    };
}

1;
