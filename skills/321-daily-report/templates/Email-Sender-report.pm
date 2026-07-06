# Copyright Nige Ltd. Author: Nigel Hamilton.
package F6::Email::Sender;

#------------------------------------------------------------------------------
# Nigel Hamilton
#
# Filename:     Email-Sender-report.pm (excerpt of lib/F6/Email/Sender.pm)
# Description:  The daily-report surface of the app's Postmark sender, shipped
#               from app.favsix.com. The AXS baseline (321-bootstrap-saas)
#               already gives you this package with send_passcode + _send +
#               _shell; ADD send_daily_report/_report_table/_delta_html and
#               REPLACE _shell with this preheader-aware version (+ _escape).
#               With no server token configured the message is logged instead,
#               so it works in development and tests without email infra.
#------------------------------------------------------------------------------

use Mojo::Base -base, -signatures;

use Mojo::UserAgent;
use Time::HiRes ();

has 'log';
has from   => 'hello@favsix.com';
has token  => '';
has stream => 'outbound';
has ua     => sub { Mojo::UserAgent->new->connect_timeout(5)->request_timeout(15) };

# ... app-specific transactional methods (send_passcode, send_invite, ...)
# elided; they are unchanged from the baseline sender ...

#------------------------------------------------------------------------------
# send_daily_report - the owner's nightly platform summary
#   $summary is the hash from F6::Model::Reporting->daily_summary
#------------------------------------------------------------------------------
sub send_daily_report ($self, $to, $summary) {

    my $g = $summary->{growth};
    my $e = $summary->{engagement};
    my $b = $summary->{billing};

    my $subject = sprintf 'FavSix daily - %s: %d signups, %d active',
        $summary->{date}, $g->{signups}{value}, $e->{active_users}{value};

    my $growth = $self->_report_table('Growth', [
        ['New signups',      $g->{signups}],
        ['New teams',        $g->{teams}],
        ['New FavSixes',     $g->{favsixes}],
        ['New tiles',        $g->{tiles}],
        ['Invites sent',     $g->{invites_sent}],
        ['Invites accepted', $g->{invites_accepted}],
    ]);
    my $engage = $self->_report_table('Engagement', [
        ['Active users',     $e->{active_users}],
        ['Tile clicks',      $e->{clicks}],
        ['Form submissions', $e->{submissions}],
    ]);
    my $revenue = $self->_report_table('Revenue & billing', [
        ['Trials started',    $b->{trials_started}],
        ['Payments received', $b->{payments_received}],
    ]);

    my $busiest = '<p style="margin:0 0 6px;color:#5C7388;font-size:13px;font-weight:800;text-transform:uppercase;letter-spacing:0.04em;">Busiest FavSixes</p>';
    if (@{ $e->{busiest} }) {
        $busiest .= '<ol style="margin:0 0 18px;padding-left:20px;color:#1F2433;">';
        for my $row (@{ $e->{busiest} }) {
            $busiest .= sprintf
                '<li style="margin:2px 0;">%s <span style="color:#5C7388;">@%s</span> &middot; <strong>%d</strong></li>',
                _escape($row->{title}), _escape($row->{handle}), $row->{n};
        }
        $busiest .= '</ol>';
    } else {
        $busiest .= '<p style="margin:0 0 18px;color:#5C7388;">No activity yet.</p>';
    }

    my $f = $b->{funnel};
    my $funnel = sprintf
        '<p style="margin:0;color:#5C7388;font-size:13px;">Funnel: '
      . 'free <strong>%d</strong> &middot; trialing <strong>%d</strong> &middot; '
      . 'active <strong>%d</strong> &middot; past-due <strong>%d</strong> &middot; '
      . 'canceled <strong>%d</strong> &middot; other <strong>%d</strong> &middot; '
      . 'billable active <strong>%d</strong></p>',
        $f->{free}, $f->{trialing}, $f->{active}, $f->{past_due}, $f->{canceled},
        $f->{other}, $b->{billable_active_users};

    my $body =
        qq{<h2 style="margin:0 0 4px;font-size:20px;font-weight:900;letter-spacing:-0.01em;color:#1F2433;">Daily report</h2>}
      . qq{<p style="margin:0 0 18px;color:#5C7388;font-size:14px;">$summary->{date} (Europe/London)</p>}
      . $growth . $engage . $revenue . $busiest . $funnel;

    my $preheader = sprintf '%d signups, %d active users, %d clicks',
        $g->{signups}{value}, $e->{active_users}{value}, $e->{clicks}{value};

    return $self->_send($to, $subject, $self->_shell($body, $preheader));
}

#------------------------------------------------------------------------------
# _report_table - a labelled section: metric | value | delta | 7-day avg
#------------------------------------------------------------------------------
sub _report_table ($self, $heading, $rows) {
    my $html =
        qq{<p style="margin:0 0 6px;color:#5C7388;font-size:13px;font-weight:800;text-transform:uppercase;letter-spacing:0.04em;">}
      . _escape($heading) . q{</p>}
      . q{<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="margin:0 0 18px;border-collapse:collapse;">};
    for my $r (@$rows) {
        my ($label, $cell) = @$r;
        $html .=
            q{<tr>}
          . qq{<td style="padding:4px 0;color:#1F2433;font-size:14px;">@{[ _escape($label) ]}</td>}
          . qq{<td style="padding:4px 0;text-align:right;font-weight:900;color:#1F2433;font-size:14px;">$cell->{value}</td>}
          . qq{<td style="padding:4px 0 4px 12px;text-align:right;font-size:13px;">@{[ $self->_delta_html($cell) ]}</td>}
          . qq{<td style="padding:4px 0 4px 12px;text-align:right;color:#5C7388;font-size:12px;">avg $cell->{avg7}</td>}
          . q{</tr>};
    }
    return $html . q{</table>};
}

#------------------------------------------------------------------------------
# _delta_html - coloured arrow + difference vs the prior day
#------------------------------------------------------------------------------
sub _delta_html ($self, $cell) {
    my $diff = $cell->{value} - $cell->{prev};
    return q{<span style="color:#5C7388;">&#9644; 0</span>} if $cell->{dir} eq 'flat';
    my ($arrow, $colour) = $cell->{dir} eq 'up'
        ? ('&#9650;', '#128C66')
        : ('&#9660;', '#E55B47');
    return sprintf '<span style="color:%s;">%s %+d</span>', $colour, $arrow, $diff;
}

#------------------------------------------------------------------------------
# _shell - wrap body HTML in a branded email frame (logo + footer)
#   Uses table-based layout + inline styles for broad email-client support.
#   Logo references favsix.com (the live host) so it always resolves -
#   transactional emails are only meaningfully sent from live anyway.
#------------------------------------------------------------------------------
sub _shell ($self, $body, $preheader = '') {
    my $preheader_html = '';
    if (length $preheader) {
        my $p = _escape($preheader);
        $preheader_html = qq{<div style="display:none;max-height:0;overflow:hidden;mso-hide:all;">$p</div>};
    }
    return <<"HTML";
<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>FavSix</title></head>
<body style="margin:0;padding:0;background:#F4EFE5;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,'Helvetica Neue',Arial,sans-serif;color:#1F2433;line-height:1.5;">
$preheader_html
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:#F4EFE5;">
  <tr><td align="center" style="padding:32px 12px;">
    <table role="presentation" width="560" cellpadding="0" cellspacing="0" border="0" style="max-width:560px;width:100%;background:#FFFFFF;border-radius:16px;overflow:hidden;">
      <tr><td style="padding:20px 28px;border-bottom:2px solid #E55B47;">
        <table role="presentation" cellpadding="0" cellspacing="0" border="0"><tr>
          <td style="vertical-align:middle;"><img src="https://favsix.com/favicons/favicon-48x48.png" width="32" height="32" alt="" style="display:block;border:0;"></td>
          <td style="padding-left:10px;vertical-align:middle;font-weight:900;font-size:20px;letter-spacing:-0.02em;color:#1F2433;">FavSix</td>
        </tr></table>
      </td></tr>
      <tr><td style="padding:28px;">
        $body
      </td></tr>
      <tr><td style="padding:16px 28px;border-top:1px solid #E4E4EE;color:#5C7388;font-size:12px;">
        <strong style="color:#1F2433;">Six of your best.</strong> &middot;
        <a href="https://favsix.com" style="color:#5C7388;text-decoration:none;">favsix.com</a>
        <br>
        FavSix is operated by <a href="https://nigelhamilton.com" style="color:#5C7388;text-decoration:none;">Nige Ltd</a>.
      </td></tr>
    </table>
  </td></tr>
</table>
</body></html>
HTML
}

#------------------------------------------------------------------------------
# _escape - minimal HTML escaping for notification bodies
#------------------------------------------------------------------------------
sub _escape ($value) {
    my $v = defined $value ? "$value" : '';
    $v =~ s/&/&amp;/g;
    $v =~ s/</&lt;/g;
    $v =~ s/>/&gt;/g;
    return $v;
}

#------------------------------------------------------------------------------
# _send - deliver via Postmark, or log when no token is configured
#------------------------------------------------------------------------------
sub _send ($self, $to, $subject, $html, $log_hint = undef) {

    unless (length $self->token) {
        $self->log->info("[email:log] to=$to subject=$subject"
            . (defined $log_hint ? " code=$log_hint" : ''));
        return { ok => 1, delivery => 'log' };
    }

    my $log   = $self->log;
    my $start = Time::HiRes::time();

    # Blocking call. This is only reached from a cron-run command or a Minion
    # task body - a worker process is the right place to wait. Non-blocking
    # variants queue a callback on an IOLoop whose lifetime doesn't match:
    # controllers tear the UA down on return; Minion children exit as soon as
    # the task body returns, killing the in-flight Postmark request.
    my $tx  = $self->ua->post(
        'https://api.postmarkapp.com/email' => {
            'Accept'                  => 'application/json',
            'Content-Type'            => 'application/json',
            'X-Postmark-Server-Token' => $self->token,
        } => json => {
            From          => $self->from,
            To            => $to,
            Subject       => $subject,
            HtmlBody      => $html,
            MessageStream => $self->stream,
        }
    );
    my $ms  = int((Time::HiRes::time() - $start) * 1000);
    my $res = $tx->result;

    if ($res && $res->is_success) {
        $log->info("[email:postmark] sent to=$to subject=\"$subject\" in ${ms}ms");
        return { ok => 1, delivery => 'postmark' };
    }

    my $error = ($res && eval { $res->json->{Message} })
              || ($res && $res->message)
              || 'send failed';
    $log->error("[email:postmark] to=$to failed in ${ms}ms: $error");
    die "Postmark send failed: $error";
}

1;
