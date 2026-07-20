package Deploy::GoBin;

use Mojo::Base -base, -signatures;

has [qw(repo gobin secrets runner s3 log exec)];

sub _parse_semver ($v) {
    die "not valid semver: '$v'\n" unless defined $v && $v =~ /^(\d+)\.(\d+)\.(\d+)$/;
    return ($1, $2, $3);
}

sub semver_cmp ($a, $b) {
    my @a = _parse_semver($a);
    my @b = _parse_semver($b);
    return $a[0] <=> $b[0] || $a[1] <=> $b[1] || $a[2] <=> $b[2];
}

sub bump_semver ($current, $level) {
    my ($maj, $min, $pat) = _parse_semver($current);
    return "$maj.$min." . ($pat + 1) if $level eq 'patch';
    return "$maj." . ($min + 1) . ".0" if $level eq 'minor';
    return ($maj + 1) . ".0.0"          if $level eq 'major';
    die "unknown bump level: '$level' (want patch|minor|major)\n";
}

sub resolve_version ($self, %opt) {
    my $latest = $opt{latest};
    my $version = defined $opt{version}
        ? $opt{version}
        : bump_semver($latest // '0.0.0', $opt{bump} // 'patch');
    _parse_semver($version);   # validates or dies
    if (defined $latest && semver_cmp($version, $latest) <= 0) {
        die "version $version must be newer than the current latest $latest\n";
    }
    return $version;
}

1;
