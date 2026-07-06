# Copyright Nige Ltd. Author: Nigel Hamilton.
package L2D::Auth::Passcodes;

#------------------------------------------------------------------------------
# Issue and verify single-use 6-digit sign-in passcodes. The plaintext code is
# emailed; only its SHA-256 hash is stored. Verification consumes the code
# atomically so it can be used exactly once.
#------------------------------------------------------------------------------

use Mojo::Base -base, -signatures;
use Digest::SHA qw(sha256_hex);

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
# issue - generate + store a hashed passcode for an email. Returns the
#   plaintext code (to email) on success, or an error hash.
#------------------------------------------------------------------------------
sub issue ($self, $email, $user_agent = undef, $ip_address = undef) {

    $email = $self->normalise_email($email);

    return { ok => 0, error => 'invalid_email' }
        unless $email =~ /\A[^@\s]+@[^@\s]+\z/;

    my $code = sprintf '%06d', int(rand(1_000_000));

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
