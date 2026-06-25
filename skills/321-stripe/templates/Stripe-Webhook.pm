# 321-stripe skill template — port to <NS>::Stripe::Webhook ; see SKILL.md
package <NS>::Stripe::Webhook;

#------------------------------------------------------------------------------
# Nigel Hamilton
#
# Filename:     Webhook.pm
# Description:  Verify Stripe webhook signatures before trusting any event.
#               Signed payload is "<timestamp>.<raw body>"; the v1 signature is
#               HMAC-SHA256 of that under the endpoint's signing secret.
#------------------------------------------------------------------------------

use Mojo::Base -strict, -signatures;

use Digest::SHA qw(hmac_sha256_hex);
use Mojo::JSON  qw(decode_json);

use constant TOLERANCE => 5 * 60;   # seconds

#------------------------------------------------------------------------------
# verify - ($ok, $event_or_error) = verify($body, $sig_header, $secret, $now)
#------------------------------------------------------------------------------
sub verify ($class, $body, $sig_header, $secret, $now) {
    my ($t, @v1);
    for my $pair (split /,/, ($sig_header // '')) {
        my ($k, $v) = split /=/, $pair, 2;
        next unless defined $k && defined $v;
        if    ($k eq 't')  { $t  = $v }
        elsif ($k eq 'v1') { push @v1, $v }
    }
    return (0, { error => 'malformed signature header' })
        unless defined $t && $t =~ /\A\d+\z/ && @v1;

    return (0, { error => 'timestamp outside tolerance' })
        if abs($now - $t) > TOLERANCE;

    # During signing-secret rotation Stripe sends several v1 signatures; accept
    # if any matches (constant-time compare per candidate, fail closed).
    my $expected = hmac_sha256_hex("$t.$body", $secret);
    my $matched  = 0;
    for my $cand (@v1) { $matched = 1 if _const_eq($expected, $cand) }
    return (0, { error => 'signature mismatch' }) unless $matched;

    my $event = eval { decode_json($body) };
    return (0, { error => 'invalid JSON' }) unless defined $event;
    return (1, $event);
}

#------------------------------------------------------------------------------
# _const_eq - constant-time string compare (avoids timing side channels)
#------------------------------------------------------------------------------
sub _const_eq ($a, $b) {
    return 0 unless length $a == length $b;
    my $diff = 0;
    $diff |= ord(substr $a, $_, 1) ^ ord(substr $b, $_, 1) for 0 .. length($a) - 1;
    return $diff == 0 ? 1 : 0;
}

1;
