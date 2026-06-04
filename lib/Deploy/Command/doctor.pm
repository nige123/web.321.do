package Deploy::Command::doctor;

use Mojo::Base 'Deploy::Command', -signatures;
use Path::Tiny qw(path);

has description => 'Probe SSL certs of every live host and report mismatches';
has usage => sub ($self) { $self->extract_usage };

sub run ($self, @args) {
    my ($_unused, $target) = $self->parse_target(@args);
    $target ||= 'live';
    $self->config->target($target);

    my @rows;
    for my $name (@{ $self->config->service_names }) {
        my $svc = $self->config->service($name);
        next unless $svc;
        next if $svc->{is_worker};
        my $host = $svc->{host} // 'localhost';
        next if $host eq 'localhost';

        my $probe = $self->nginx->probe_cert($host);
        push @rows, { name => $name, host => $host, probe => $probe };
    }

    my $bad = grep { !$_->{probe}{ok} } @rows;
    say "Checked " . scalar(@rows) . " host(s) on $target target ("
        . ($bad ? "\e[31m$bad failing\e[0m" : "\e[32mall good\e[0m") . ")";
    say "";

    for my $row (@rows) {
        my $p = $row->{probe};
        if ($p->{ok}) {
            printf "  \e[32m[OK]\e[0m   %-30s %s\n", $row->{name}, $row->{host};
        } else {
            printf "  \e[31m[FAIL]\e[0m %-30s %s\n", $row->{name}, $row->{host};
            say   "         $p->{error}" if $p->{error};
            say   "         Fix: 321 go $row->{name} $target" unless $p->{error} && $p->{error} =~ /no TLS/;
        }
    }

    my $inc_bad = $self->_audit_inc;

    exit 1 if $bad || $inc_bad;
}

# Audit every service repo's bin/*.pl for the fragile @INC glob (see
# scan_inc). Source-only — target-independent — so it works on dev too.
# Returns the number of offending files found.
sub _audit_inc ($self) {
    my @hits;
    my %seen;
    for my $name (@{ $self->config->service_names }) {
        my $svc = $self->config->service($name) or next;
        next if $svc->{is_worker};
        my $repo = $svc->{repo} or next;
        next if $seen{$repo}++;
        my $bin = path($repo, 'bin');
        next unless $bin->is_dir;
        for my $file (sort $bin->children(qr/\.pl$/)) {
            my $found = $self->scan_inc(scalar $file->slurp_utf8);
            push @hits, { file => "$file", %$_ } for @$found;
        }
    }

    say "";
    say "\@INC audit ("
        . (@hits ? "\e[31m" . scalar(@hits) . " issue(s)\e[0m" : "\e[32mall good\e[0m")
        . ")";
    return 0 unless @hits;

    say "";
    for my $h (@hits) {
        printf "  \e[31m[INC]\e[0m  %s:%d\n", $h->{file}, $h->{line};
        say   "         $h->{text}";
    }
    say "";
    say "  This globs every subdir of local/lib/perl5 onto \@INC, where a";
    say "  namespace dir (e.g. HTTP/) shadows core Config.pm and breaks";
    say "  `use Config` in File::Copy/Mojo::File. 321 already sets PERL5LIB,";
    say "  so the arch dir loads automatically — drop the glob, or resolve";
    say "  just the arch dir via \$Config{archname}.";
    return scalar @hits;
}

# scan_inc($text) — pure scanner. Returns [ { line, text }, ... ] for each
# line that globs the whole local/lib/perl5 tree onto @INC (a bare trailing
# '*'). Arch-restricted globs ('*-linux*') and $Config{archname} resolution
# are correct and not flagged.
sub scan_inc ($class, $text) {
    my @hits;
    my @lines = split /\n/, $text // '';
    for my $i (0 .. $#lines) {
        next unless $lines[$i] =~ m{ \bglob\b [^\n]* local/lib/perl5/\* (["']) }x;
        (my $trim = $lines[$i]) =~ s/^\s+//;
        push @hits, { line => $i + 1, text => $trim };
    }
    return \@hits;
}

1;

=head1 SYNOPSIS

  Usage: APPLICATION doctor [target]

  Probes every non-localhost service host on the target (default: live)
  and reports any cert that doesn't match its hostname. Then audits every
  service repo's bin/*.pl for the fragile @INC glob (globbing the whole
  local/lib/perl5 tree onto @INC, which shadows core Config). Exit code is
  non-zero when any check fails — wire it into a cron if you want alerts.

  321 doctor             # check live
  321 doctor live        # explicit
  321 doctor dev         # also works for dev (mkcert)

=cut
