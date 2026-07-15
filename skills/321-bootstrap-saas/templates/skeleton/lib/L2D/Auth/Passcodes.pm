# Copyright Nige Ltd. Author: Nigel Hamilton.
package L2D::Auth::Passcodes;

#------------------------------------------------------------------------------
# Issue and verify single-use 6-digit sign-in passcodes. The plaintext code is
# emailed; only its SHA-256 hash is stored. Verification consumes the code
# atomically so it can be used exactly once.
#------------------------------------------------------------------------------

use Mojo::Base -base, -signatures;
use Digest::SHA qw(sha256_hex);
use Crypt::URandom qw(urandom);

has 'db';      # L2D::DB

#------------------------------------------------------------------------------
# normalise_email - lowercase and trim.
#------------------------------------------------------------------------------
sub normalise_email ($self, $email) {
    $email //= '';
    $email =~ s/\A\s+|\s+\z//g;
    return lc $email;
}

#------------------------------------------------------------------------------
# _random_code - uniform 0..999999 from the OS CSPRNG. A login OTP must never
#   come from perl's rand() (seedable, predictable). And a raw 32-bit draw
#   reduced % 1_000_000 is biased low, because 2**32 is not an exact multiple
#   of the range: rejection-sample instead - redraw whenever the value lands
#   at or above the largest exact multiple (4_294_000_000, ~0.02% of draws),
#   and only then take the modulo.
#------------------------------------------------------------------------------
sub _random_code ($self) {
    my $n;
    do { $n = unpack 'N', urandom(4) } while $n >= 4_294_000_000;
    return $n % 1_000_000;
}

#------------------------------------------------------------------------------
# issue - generate + store a hashed passcode for an email. Returns the
#   plaintext code (to email) on success, or an error hash.
#------------------------------------------------------------------------------
sub issue ($self, $email, $user_agent = undef, $ip_address = undef) {

    $email = $self->normalise_email($email);

    return { ok => 0, error => 'invalid_email' }
        unless $email =~ /\A[^@\s]+@[^@\s]+\z/;

    my $code = sprintf '%06d', $self->_random_code;

    my $row = $self->db->query('passcodes/issue', {
        email => $email,
        code  => sha256_hex($code),
    })->hash;

    return { ok => 0, error => 'rate_limited' } unless $row;

    return {
        ok         => 1,
        email      => $email,
        code       => $code,
        expires_at => $row->{expires_at},
    };
}

#------------------------------------------------------------------------------
# verify - check a submitted code; consumes it atomically on success.
#------------------------------------------------------------------------------
sub verify ($self, $email, $code) {

    $email = $self->normalise_email($email);
    $code //= '';

    return { ok => 0, error => 'invalid' }
        unless $email =~ /\A[^@\s]+@[^@\s]+\z/ && $code =~ /\A\d{6}\z/;

    my $row = $self->db->query('passcodes/verify', {
        email => $email,
        code  => sha256_hex($code),
    })->hash;

    return { ok => 0, error => 'invalid' } unless $row;

    return { ok => 1, email => $row->{email} };
}

1;
