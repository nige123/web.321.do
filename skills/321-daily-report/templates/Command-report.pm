# Copyright Nige Ltd. Author: Nigel Hamilton.
package F6::Command::report;

#------------------------------------------------------------------------------
# Nigel Hamilton
#
# Filename:     report.pm
# Description:  Mojolicious subcommand: build the platform-wide daily usage
#               summary and email it to the owner. One-shot; run nightly by
#               cron, or by hand. Idempotent per date via daily_reports.
#               Usage: ./bin/app.pl report [YYYY-MM-DD] [--dry-run] [--force] [--to=ADDR]
#------------------------------------------------------------------------------

use Mojo::Base 'Mojolicious::Command', -signatures;

use Getopt::Long qw(GetOptionsFromArray);
use F6::Model::Reporting;

has description => 'Send the daily owner usage report';
has usage       => "Usage: APPLICATION report [YYYY-MM-DD] [--dry-run] [--force] [--to=ADDR]\n";

sub run ($self, @args) {

    my ($dry, $force, $to);
    GetOptionsFromArray(\@args,
        'dry-run' => \$dry,
        'force'   => \$force,
        'to=s'    => \$to);

    my $app = $self->app;

    my $report_date = shift @args;
    if (defined $report_date) {
        die $self->usage unless $report_date =~ /\A\d{4}-\d{2}-\d{2}\z/;
    }
    else {
        $report_date = $app->db->raw(
            q{SELECT to_char((now() AT TIME ZONE 'Europe/London')::date - 1, 'YYYY-MM-DD') AS d}
        )->hash->{d};
    }

    my $recipient = $to // $app->config('daily_report_to') // '';

    if (!length $recipient && !$dry) {
        $app->log->info("[report] no recipient configured - skipping $report_date");
        return;
    }

    if (!$force && !$dry) {
        my $seen = $app->db->raw(
            'SELECT 1 FROM daily_reports WHERE report_date = ?', $report_date)->rows;
        if ($seen) {
            $app->log->info("[report] already sent for $report_date");
            return;
        }
    }

    my $summary = F6::Model::Reporting->new(db => $app->db)->daily_summary($report_date);

    if ($dry) {
        say sprintf '%s: signups=%d teams=%d active=%d clicks=%d trials=%d',
            $summary->{date},
            $summary->{growth}{signups}{value},
            $summary->{growth}{teams}{value},
            $summary->{engagement}{active_users}{value},
            $summary->{engagement}{clicks}{value},
            $summary->{billing}{trials_started}{value};
        return;
    }

    my $res = $app->email_sender->send_daily_report($recipient, $summary);
    die "[report] send failed for $report_date\n" unless $res->{ok};

    $app->db->raw(
        'INSERT INTO daily_reports (report_date, recipient) VALUES (?, ?)
         ON CONFLICT (report_date) DO UPDATE SET recipient = EXCLUDED.recipient, sent_at = now()',
        $report_date, $recipient);

    $app->log->info("[report] sent $report_date to $recipient (delivery=$res->{delivery})");
    return;
}

1;
