package Deploy::Transport;

use Mojo::Base -strict, -signatures;
use Deploy::Local;
use Deploy::SSH;

# for_target($class, $target, %opts) — factory that returns the right transport.
# If $target->{ssh} exists, parse user@host and return Deploy::SSH.
# Otherwise return Deploy::Local.
# Passes perlbrew through to whichever transport is constructed.
sub for_target ($class, $target, %opts) {
    if ($target->{ssh}) {
        my ($user, $host) = split /\@/, $target->{ssh}, 2;
        return Deploy::SSH->new(
            user => $user,
            host => $host,
            key  => $target->{ssh_key},
            ($opts{perlbrew} ? (perlbrew => $opts{perlbrew}) : ()),
        );
    }

    return Deploy::Local->new(
        ($opts{perlbrew} ? (perlbrew => $opts{perlbrew}) : ()),
    );
}

1;
