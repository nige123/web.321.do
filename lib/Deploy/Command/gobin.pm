package Deploy::Command::gobin;

use Mojo::Base 'Deploy::Command', -signatures;
use Deploy::GoBin;
use Deploy::GoBin::Runner;
use Deploy::GoBin::S3;

has description => 'Build, sign, and release cross-arch Go binaries';
has usage => sub ($self) { $self->extract_usage };

sub run ($self, @args) {
    my $verb = shift @args // '';
    my %o = $self->_parse_flags(@args);

    my $name = $self->_infer_service
        or die "Run inside a Go repo whose 321.yml has a gobin: block.\n";
    my $svc = $self->config->service($name)
        or die "Unknown service: $name\n";
    my $block = $svc->{gobin}
        or die "$name has no gobin: block in 321.yml.\n";

    my $gobin = $self->_gobin_for($svc, $block);

    return $self->_make($gobin, %o)           if $verb eq 'make';
    return $self->_release($gobin, %o)        if $verb eq 'release';
    return $self->_rollback($gobin)           if $verb eq 'rollback';
    return $self->_status($gobin)             if $verb eq 'status';
    die $self->usage;
}

sub _parse_flags ($self, @args) {
    my %o;
    while (defined(my $a = shift @args)) {
        if    ($a =~ /^--bump=(patch|minor|major)$/) { $o{bump}          = $1 }
        elsif ($a eq '--bump')                       { $o{bump}          = shift @args }
        elsif ($a =~ /^--version=(.+)$/)             { $o{version}       = $1 }
        elsif ($a =~ /^--min-supported=(.+)$/)       { $o{min_supported} = $1 }
        elsif ($a =~ /^(\d+\.\d+\.\d+)$/)            { $o{version}       = $1 }
    }
    return %o;
}

sub _gobin_for ($self, $svc, $block) {
    my $repo    = $svc->{repo};
    my $secrets = Deploy::GoBin::load_secrets($repo);
    return Deploy::GoBin->new(
        repo    => $repo,
        gobin   => $block,
        secrets => $secrets,
        runner  => Deploy::GoBin::Runner->new,
        s3      => Deploy::GoBin::S3->new(
            bucket => $block->{s3}{bucket},
            creds  => $secrets,
        ),
        log     => $self->app->log,
    );
}

sub _make ($self, $gobin, %o) {
    my $latest = $gobin->live_latest;   # undef when no manifest yet
    my $r = $gobin->make(%o, latest => $latest);
    say "Built v$r->{version} (" . ($r->{generated} ? 'generated' : 'checked-in') . " config)";
    say "  meta: $r->{meta_path}";
    say "  run '321 gobin release' to publish.";
}

sub _release ($self, $gobin, %o) {
    my $r = $gobin->release(defined $o{version} ? (version => $o{version}) : ());
    say "Released v$r->{version}:";
    say "  " . scalar(@{ $r->{uploaded} }) . " objects uploaded";
    say $r->{verified} ? "  verified: all URLs + signatures resolve"
                       : "  \e[31mWARNING: verification failed - release may be broken\e[0m";
}

sub _rollback ($self, $gobin) {
    my ($prev) = $gobin->rollback;
    say "Rolled back: latest is now v$prev (bytes already in S3, instant).";
}

sub _status ($self, $gobin) {
    my $r = $gobin->status;
    say "built (dist/): " . ($r->{built} // '(none)');
    say "live (latest): " . ($r->{live}  // '(none)');
    for my $arch (sort keys %{ $r->{arches} }) {
        my $a = $r->{arches}{$arch};
        printf "  %-14s built:%s  live:%s\n",
            $arch, ($a->{built} ? 'yes' : 'no '), ($a->{live} ? 'yes' : 'no ');
    }
}

1;

=head1 SYNOPSIS

  Usage: APPLICATION gobin <make|release|rollback|status> [options]

  321 gobin make --bump minor           # tag + cross-compile + sign into dist/
  321 gobin make --version 2.0.0
  321 gobin release                     # upload dist/ + update version.json
  321 gobin rollback                    # re-point latest to the previous build
  321 gobin status                      # built-locally vs live-latest, per arch

  Run inside the Go repo; its 321.yml must carry a gobin: block.

=cut
