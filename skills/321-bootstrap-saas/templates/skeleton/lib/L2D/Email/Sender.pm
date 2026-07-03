package L2D::Email::Sender;

#------------------------------------------------------------------------------
# Deliver transactional email via Postmark. With NO server token configured the
# message is LOGGED instead of sent — so sign-in works in development and tests
# with no email infrastructure. Called only from a Minion worker (the blocking
# POST needs a process that outlives the request).
#------------------------------------------------------------------------------

use Mojo::Base -base, -signatures;

use Mojo::UserAgent;
use Time::HiRes ();

has 'log';
has from   => 'hello@l2d.example';
has token  => '';
has stream => 'outbound';
has ua     => sub { Mojo::UserAgent->new->connect_timeout(5)->request_timeout(15) };

#------------------------------------------------------------------------------
# send_passcode - email a sign-in passcode.
#------------------------------------------------------------------------------
sub send_passcode ($self, $to, $code) {

    my $subject = 'Your sign-in code';
    my $body    =
        qq{<h2 style="margin:0 0 12px;font-size:20px;font-weight:800;color:#1A2240;">Your sign-in code</h2>}
      . qq{<p style="margin:18px 0;font-size:32px;letter-spacing:6px;font-weight:800;color:#4338CA;">$code</p>}
      . qq{<p style="margin:0;color:#556;font-size:14px;">This code expires in 10 minutes. If you did not request it, ignore this email.</p>};

    return $self->_send($to, $subject, $self->_shell($body), $code);
}

#------------------------------------------------------------------------------
# _shell - wrap body HTML in a minimal branded frame. Inline styles for broad
#   email-client support. Extend with your own logo/footer.
#------------------------------------------------------------------------------
sub _shell ($self, $body) {
    return <<"HTML";
<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>l2d</title></head>
<body style="margin:0;padding:0;background:#F4F5F7;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Arial,sans-serif;color:#1A2240;line-height:1.5;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:#F4F5F7;">
  <tr><td align="center" style="padding:32px 12px;">
    <table role="presentation" width="520" cellpadding="0" cellspacing="0" border="0" style="max-width:520px;width:100%;background:#fff;border-radius:14px;overflow:hidden;">
      <tr><td style="padding:28px;">
        $body
      </td></tr>
    </table>
  </td></tr>
</table>
</body></html>
HTML
}

#------------------------------------------------------------------------------
# _send - deliver via Postmark, or log when no token is configured.
#------------------------------------------------------------------------------
sub _send ($self, $to, $subject, $html, $log_hint = undef) {

    unless (length $self->token) {
        $self->log->info("[email:log] to=$to subject=$subject"
            . (defined $log_hint ? " code=$log_hint" : ''));
        return { ok => 1, delivery => 'log' };
    }

    my $log   = $self->log;
    my $start = Time::HiRes::time();

    # Blocking call — correct inside a Minion task body (the worker is the right
    # place to wait). A non-blocking variant from a controller would be torn
    # down on return before Postmark replied.
    my $tx = $self->ua->post(
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
    die "Postmark send failed: $error";   # Minion records the failure + retries
}

1;
