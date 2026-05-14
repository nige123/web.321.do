package Deploy::Manifest;

use Mojo::Base -base, -signatures;
use YAML::XS qw(LoadFile);
use Path::Tiny qw(path);

my %VALID_RUNNER = map { $_ => 1 } qw(hypnotoad morbo script);

my %IDENTITY_KEY = map { $_ => 1 } qw(
    name entry runner perl health branch repo test
    apt_deps favicon workers force_https
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
        apt_deps     => $raw->{apt_deps} // [],
        targets      => \%targets,
        repo         => "$repo_dir",
        ($raw->{repo}    ? (git_url => $raw->{repo})    : ()),
        ($raw->{test}    ? (test    => $raw->{test})    : ()),
        ($raw->{favicon} ? (favicon => $raw->{favicon}) : ()),
        ($raw->{workers} ? (workers => $raw->{workers}) : ()),
        (exists $raw->{force_https} ? (force_https => $raw->{force_https}) : ()),
    };
}

1;
