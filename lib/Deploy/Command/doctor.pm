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

    my ($fail, $warn) = (0, 0);
    for my $row (@rows) {
        my ($tier, $msg) = _tier($row->{probe});
        $row->{tier} = $tier;
        $row->{msg}  = $msg;
        $fail++ if $tier eq 'fail';
        $warn++ if $tier eq 'warn';
    }

    my @summary;
    push @summary, "\e[31m$fail failing\e[0m"  if $fail;
    push @summary, "\e[33m$warn expiring\e[0m"  if $warn;
    push @summary, "\e[32mall good\e[0m"        unless @summary;
    say "Checked " . scalar(@rows) . " host(s) on $target target (" . join(', ', @summary) . ")";
    say "";

    for my $row (@rows) {
        my %label = (ok => "\e[32m[OK]\e[0m  ", warn => "\e[33m[WARN]\e[0m", fail => "\e[31m[FAIL]\e[0m");
        printf "  %s %-30s %s\n", $label{ $row->{tier} }, $row->{name}, $row->{host};
        next if $row->{tier} eq 'ok';
        say "         $row->{msg}" if $row->{msg};
        # 321 go can renew/repair a cert; it cannot fix an unreachable host.
        say "         Fix: 321 go $row->{name} $target" if $row->{probe}{reachable} // 1;
    }

    my $inc_bad = $self->_audit_inc;

    exit 1 if $fail || $warn || $inc_bad;
}

# Classify a probe_cert result into (tier, message). 'warn' = a valid cert
# inside the 30-day renewal window (renew soon); 'fail' = expired, wrong host,
# or unreachable. Pure - unit tested.
sub _tier ($probe) {
    return ('fail', $probe->{error} // 'no valid certificate') unless $probe->{ok};
    return ('warn', "certificate expires in $probe->{days_remaining} days") if $probe->{expiring};
    my $d = $probe->{days_remaining};
    return ('ok', defined $d ? "valid, $d days left" : 'valid');
}

sub _needs_attention ($tier) { return ($tier eq 'fail' || $tier eq 'warn') ? 1 : 0 }

# Audit every service repo's bin/*.pl for the fragile @INC glob (see
# scan_inc). Source-only - target-independent - so it works on dev too.
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
    say "  so the arch dir loads automatically - drop the glob, or resolve";
    say "  just the arch dir via \$Config{archname}.";
    return scalar @hits;
}

# scan_inc($text) - pure scanner. Returns [ { line, text }, ... ] for each
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
  and reports each cert as OK, WARN (valid but expiring within 30 days),
  or FAIL (expired, wrong host, or unreachable - the message names which
  layer). Then audits every service repo's bin/*.pl for the fragile @INC
  glob (globbing the whole local/lib/perl5 tree onto @INC, which shadows
  core Config). Exit code is non-zero when any cert is failing OR expiring,
  so a cron catches a cert BEFORE it lapses.

  321 doctor             # check live
  321 doctor live        # explicit
  321 doctor dev         # also works for dev (mkcert)

=cut
