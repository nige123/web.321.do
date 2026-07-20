package Deploy::GoBin;

use Mojo::Base -base, -signatures;
use YAML::XS qw(Dump);
use Path::Tiny qw(path);

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

our @DEFAULT_TARGETS = qw(linux/amd64 linux/arm64 darwin/arm64 darwin/amd64 windows/amd64);

sub _targets ($self) {
    my $t = $self->gobin->{targets};
    return (ref $t eq 'ARRAY' && @$t) ? @$t : @DEFAULT_TARGETS;
}

sub goreleaser_yaml ($self, $version) {
    my $b = $self->gobin;
    my (%os, %arch);
    for my $t ($self->_targets) {
        my ($o, $a) = split m{/}, $t, 2;
        $os{$o} = 1; $arch{$a} = 1;
    }
    my $doc = {
        version      => 2,
        project_name => $b->{name},
        builds => [{
            id       => $b->{name},
            binary   => $b->{name},
            main     => $b->{main} // '.',
            env      => ['CGO_ENABLED=0'],
            ldflags  => ['-s -w -X ' . $b->{version_var} . '=' . $version],
            goos     => [sort keys %os],
            goarch   => [sort keys %arch],
        }],
        archives => [{ id => $b->{name}, formats => ['tar.gz'] }],
        checksum => { name_template => 'SHA256SUMS', algorithm => 'sha256' },
        signs    => [{
            id        => 'ed25519',
            artifacts => 'all',
            cmd       => 'gobin-sign',
            args      => ['${artifact}'],
        }],
    };
    return Dump($doc);
}

sub resolve_config_path ($self, $version, %opt) {
    my $dir = $opt{dir} // $self->repo;
    my $checked_in = path($dir, '.goreleaser.yaml');
    return ($checked_in->stringify, 0) if $checked_in->exists;
    my $gen = path($dir, '.goreleaser.generated.yaml');
    $gen->spew_utf8($self->goreleaser_yaml($version));
    return ($gen->stringify, 1);
}

1;
