package Deploy::Manifest;

use Mojo::Base -base, -signatures;
use YAML::XS qw(LoadFile);
use Path::Tiny qw(path);

my %VALID_RUNNER = map { $_ => 1 } qw(hypnotoad morbo script);
my $ENV_KEY_RE   = qr/^[A-Z_][A-Z0-9_]*$/;

my %IDENTITY_KEY = map { $_ => 1 } qw(
    name entry runner perl health branch repo
    env_required env_optional apt_deps favicon
);

sub load ($class, $repo_dir) {
    my $file = path($repo_dir, '321.yml');
    return undef unless $file->exists;

    my $raw = LoadFile($file->stringify);
    die "Manifest $file: not a mapping\n" unless ref $raw eq 'HASH';

    for my $k (qw(name entry runner)) {
        die "Manifest $file: missing '$k'\n" unless defined $raw->{$k};
    }

    die "Manifest $file: unknown runner '$raw->{runner}'\n"
        unless $VALID_RUNNER{ $raw->{runner} };

    my %required = %{ $raw->{env_required} // {} };
    my %optional = %{ $raw->{env_optional} // {} };

    for my $k (keys %required, keys %optional) {
        die "Manifest $file: invalid env key '$k'\n" unless $k =~ $ENV_KEY_RE;
    }

    my %targets;
    for my $k (keys %$raw) {
        next if $IDENTITY_KEY{$k};
        next unless ref $raw->{$k} eq 'HASH';
        $targets{$k} = $raw->{$k};
    }

    return {
        name         => $raw->{name},
        entry        => $raw->{entry},
        runner       => $raw->{runner},
        perl         => $raw->{perl},
        health       => $raw->{health} // '/health',
        branch       => $raw->{branch} // 'master',
        env_required => \%required,
        env_optional => \%optional,
        apt_deps     => $raw->{apt_deps} // [],
        targets      => \%targets,
        repo         => "$repo_dir",
        ($raw->{repo}    ? (git_url => $raw->{repo})    : ()),
        ($raw->{favicon} ? (favicon => $raw->{favicon}) : ()),
    };
}

1;
