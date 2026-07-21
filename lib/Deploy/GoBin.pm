package Deploy::GoBin;

use Mojo::Base -base, -signatures;
use YAML::XS qw(Dump);
use Path::Tiny qw(path);
use Mojo::JSON qw(encode_json decode_json);

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

sub empty_manifest ($name) {
    return { name => $name, latest => undef, min_supported => undef, builds => {} };
}

sub manifest_add_build ($self, $m, %a) {
    $m->{builds}{ $a{version} } = $a{arches};
    $m->{latest}        = $a{version};
    $m->{min_supported} = $a{min_supported};
    return $m;
}

sub _versions_desc ($m) {
    return sort { semver_cmp($b, $a) } keys %{ $m->{builds} };
}

sub manifest_prune ($self, $m, $retain) {
    my @keep = (_versions_desc($m))[0 .. $retain - 1];
    my %keep = map { $_ => 1 } grep { defined } @keep;
    $keep{ $m->{latest} } = 1 if defined $m->{latest};   # never drop latest
    delete $m->{builds}{$_} for grep { !$keep{$_} } keys %{ $m->{builds} };
    return $m;
}

sub manifest_rollback ($self, $m) {
    my @desc = _versions_desc($m);
    my ($prev) = grep { semver_cmp($_, $m->{latest}) < 0 } @desc;
    die "no prior build to roll back to\n" unless defined $prev;
    $m->{latest} = $prev;
    return ($m, $prev);
}

# --- make (build + sign) --------------------------------------------------

sub preflight_make ($self, %opt) {
    my @problems;
    my $git   = $opt{git}   // $self->_default_git;
    my $which = $opt{which} // \&_which;

    my $st = $git->('git status --porcelain');
    push @problems, 'working tree is not clean (commit or stash uncommitted changes first)'
        if !$st->{ok} || ($st->{output} // '') =~ /\S/;

    my $version = eval { $self->resolve_version(%opt) };
    push @problems, ($@ =~ s/\n$//r) if $@;

    push @problems, "'go' not found on PATH"        unless $which->('go');
    push @problems, "'goreleaser' not found on PATH" unless $which->('goreleaser');

    my $key = $self->gobin->{sign_key};
    push @problems, "signing key '@{[ $key // '(unset)' ]}' missing from conf/secrets.conf"
        unless $key && ($self->secrets // {})->{$key};

    return \@problems;
}

sub make ($self, %opt) {
    my $git = $opt{git} // $self->_default_git;
    if (my @p = @{ $self->preflight_make(%opt) }) {
        die "cannot make:\n" . join('', map { "  - $_\n" } @p);
    }
    my $version       = $self->resolve_version(%opt);
    my $min_supported = $opt{min_supported} // $opt{latest} // $version;

    my $tag = "v$version";
    my $t = $git->("git tag -a $tag -m 'Release $tag'");
    die "git tag failed: $t->{output}\n" unless $t->{ok};
    my $p = $git->("git push origin $tag");
    die "git push failed: $p->{output}\n" unless $p->{ok};

    my ($config, $generated) = $self->resolve_config_path($version, dir => $self->repo);
    my $env = {
        CGO_ENABLED       => 0,
        GOBIN_SIGNING_KEY => $self->secrets->{ $self->gobin->{sign_key} },
    };
    my $run = $self->runner->run(dir => $self->repo, config => $config, env => $env);
    die "goreleaser failed: $run->{output}\n" unless $run->{ok};

    my $checksums = $self->_read_checksums(path($self->repo, 'dist'));
    my $meta = { version => $version, min_supported => $min_supported, checksums => $checksums };
    my $meta_path = path($self->repo, 'dist', 'gobin-meta.json');
    $meta_path->spew_utf8(encode_json($meta));

    return { version => $version, config => $config, generated => $generated,
             meta_path => "$meta_path" };
}

# artifact "<name>_<os>_<arch>.tar.gz" in SHA256SUMS -> { "<os>/<arch>" => sha }
sub _read_checksums ($self, $dist) {
    my $sums = path($dist, 'SHA256SUMS');
    return {} unless $sums->exists;
    my %out;
    for my $line (split /\n/, $sums->slurp_utf8) {
        next unless $line =~ /^(\S+)\s+\*?(\S+)$/;
        my ($sha, $file) = ($1, $2);
        next unless $file =~ /_([a-z0-9]+)_([a-z0-9]+)\.(?:tar\.gz|zip)$/;
        $out{"$1/$2"} = $sha;
    }
    return \%out;
}

sub _default_git ($self) {
    require Deploy::Local;
    my $local = Deploy::Local->new;
    my $repo  = $self->repo;
    return sub ($cmd) { $local->run_in_dir($repo, $cmd) };
}

sub _which ($prog) { return (`command -v $prog 2>/dev/null` =~ /\S/) ? 1 : 0 }

# --- secrets loading ------------------------------------------------------

sub load_secrets ($repo) {
    my $file = "$repo/conf/secrets.conf";
    return {} unless -f $file;
    my $h = do $file;
    return (ref $h eq 'HASH') ? $h : {};
}

# --- release (upload + manifest read-modify-write + verify) ---------------

sub _manifest_key ($self) { $self->gobin->{s3}{prefix} . '/version.json' }

sub live_manifest ($self) {
    my $r = $self->s3->get(key => $self->_manifest_key);
    return undef unless $r->{ok} && defined $r->{content};
    return decode_json($r->{content});
}

sub live_latest ($self) {
    my $m = $self->live_manifest;
    return $m ? $m->{latest} : undef;
}

# dist/ artifacts named "<name>_<os>_<arch>.tar.gz" (or .zip)
sub _dist_artifacts ($self) {
    my $dist = path($self->repo, 'dist');
    return () unless $dist->exists;
    my @arts;
    for my $f (sort { "$a" cmp "$b" } $dist->children(qr/\.(?:tar\.gz|zip)$/)) {
        my ($os, $arch) = ($f->basename =~ /_([a-z0-9]+)_([a-z0-9]+)\.(?:tar\.gz|zip)$/) or next;
        push @arts, { file => "$f", name => $f->basename, os => $os, arch => $arch };
    }
    return @arts;
}

sub preflight_release ($self, $version) {
    my @problems;
    push @problems, "nothing built for $version - run '321 gobin make' first"
        unless $self->_dist_artifacts;
    my $s = $self->secrets // {};
    push @problems, 'S3 credentials missing from conf/secrets.conf'
        unless $s->{s3_access_key_id} && $s->{s3_secret_access_key};
    return \@problems;
}

sub release ($self, %opt) {
    my $meta_path = path($self->repo, 'dist', 'gobin-meta.json');
    my $meta = $meta_path->exists ? decode_json($meta_path->slurp_utf8) : {};
    my $version = $opt{version} // $meta->{version};
    die "no version to release: pass one or run '321 gobin make' first\n" unless $version;

    if (my @p = @{ $self->preflight_release($version) }) {
        die "cannot release:\n" . join('', map { "  - $_\n" } @p);
    }

    my $prefix = $self->gobin->{s3}{prefix};
    my $checks = $meta->{checksums} // {};
    my (%per_arch, @uploaded);
    for my $a ($self->_dist_artifacts) {
        my $base = "$prefix/$version/$a->{name}";
        $self->s3->put(key => $base,       file => $a->{file},
                       content_type => 'application/gzip');
        $self->s3->put(key => "$base.sig", file => "$a->{file}.sig",
                       content_type => 'application/octet-stream');
        push @uploaded, $base, "$base.sig";
        $per_arch{"$a->{os}/$a->{arch}"} = {
            url    => $base,
            sha256 => $checks->{"$a->{os}/$a->{arch}"},
            sig    => "$base.sig",
        };
    }

    # Manifest is written once, last, after all uploads succeeded.
    my $manifest = $self->live_manifest // empty_manifest($self->gobin->{name});
    $self->manifest_add_build($manifest,
        version => $version, arches => \%per_arch,
        min_supported => $meta->{min_supported});
    $self->manifest_prune($manifest, $self->gobin->{retain} // 5);
    $self->s3->put(key => $self->_manifest_key, content => encode_json($manifest));

    # Verify: re-fetch the manifest and HEAD every url + sig it now claims.
    my $verified = 1;
    my $live = $self->live_manifest;
    for my $arch (keys %{ $live->{builds}{$version} // {} }) {
        my $b = $live->{builds}{$version}{$arch};
        $verified = 0 unless $self->s3->head(key => $b->{url})->{ok};
        $verified = 0 unless $self->s3->head(key => $b->{sig})->{ok};
    }

    return { version => $version, uploaded => \@uploaded,
             live => \%per_arch, verified => $verified };
}

1;
