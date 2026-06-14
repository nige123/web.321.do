package Deploy::Command::recycle;

use Mojo::Base 'Deploy::Command', -signatures;
use Mojo::Util qw(getopt);
use Deploy::Local;
use Deploy::Ubic;

has description => 'Restart local dev services whose memory has grown too big';
has usage => sub ($self) { $self->extract_usage };

# Morbo (the dev runner) never recycles its worker, so dev services grow
# until restarted - unlike live, where hypnotoad's `accepts` retires workers
# automatically. This command is the dev-side counterpart: measure each
# running local service's process tree and bounce the ones past a threshold.
# Designed to run from cron; prints nothing when everything is healthy.

sub run ($self, @args) {
    my $threshold = 1000;   # MB
    my $dry       = 0;
    getopt \@args,
        'threshold=i' => \$threshold,
        'n|dry-run'   => \$dry;

    my $target = 'dev';
    $self->config->target($target);

    my $local  = Deploy::Local->new;
    # ubic status exits non-zero when any service is off; parse anyway.
    my $status = Deploy::Ubic->parse_status_output(
        $local->run('ubic status')->{output}
    );
    my $ps = $local->run('ps -eo pid,ppid,rss')->{output} // '';

    my @candidates;
    for my $name (@{ $self->config->service_names }) {
        my $raw = $self->config->service_raw($name);
        next unless $raw && $raw->{targets}{dev};   # local services only
        my $pid = $status->{$name}{pid} or next;    # not running - nothing to recycle
        push @candidates, {
            name   => $name,
            rss_mb => $self->tree_rss_mb($ps, $pid),
            ($raw->{_parent} ? (parent => $raw->{_parent}) : ()),
        };
    }

    my $picked = $self->pick_recyclable(\@candidates, $threshold);
    return unless @$picked;   # quiet when healthy - keeps the cron log clean

    say scalar(localtime) . " - recycling over ${threshold}MB:";
    say "  $_->{name} at $_->{rss_mb}MB" for @$picked;
    return if $dry;

    require Deploy::Command::restart;
    for my $c (@$picked) {
        Deploy::Command::restart->new(app => $self->app)->run($c->{name}, $target);
    }
}

# tree_rss_mb($ps_text, $root_pid) - total RSS in MB of a pid and all its
# descendants, from one `ps -eo pid,ppid,rss` snapshot. The ubic-supervised
# pid is the morbo parent; the bloat lives in its forked worker child, so a
# single-pid RSS would badly under-measure.
sub tree_rss_mb ($class, $ps_text, $root) {
    my (%rss, %kids);
    for my $line (split /\n/, $ps_text // '') {
        next unless $line =~ /^\s*(\d+)\s+(\d+)\s+(\d+)\s*$/;
        my ($pid, $ppid, $kb) = ($1, $2, $3);
        $rss{$pid} = $kb;
        push @{ $kids{$ppid} }, $pid;
    }
    return 0 unless exists $rss{$root};
    my $total = 0;
    my @stack = ($root);
    while (defined(my $pid = pop @stack)) {
        $total += $rss{$pid} // 0;
        push @stack, @{ $kids{$pid} // [] };
    }
    return int($total / 1024);
}

# pick_recyclable(\@candidates, $threshold) - candidates over the threshold,
# sorted by name. A worker whose parent is also picked is dropped: restarting
# the parent already cascades to its workers.
sub pick_recyclable ($class, $candidates, $threshold) {
    my @over   = grep { $_->{rss_mb} > $threshold } @$candidates;
    my %picked = map { ($_->{name} => 1) } @over;
    @over = grep { !($_->{parent} && $picked{ $_->{parent} }) } @over;
    return [ sort { $a->{name} cmp $b->{name} } @over ];
}

1;

=head1 SYNOPSIS

  Usage: APPLICATION recycle [--threshold MB] [-n|--dry-run]

  Restarts every running local (dev) service whose process tree exceeds
  the memory threshold (default 1000 MB). Workers are folded into their
  parent's restart cascade. Prints nothing when all services are healthy,
  so it is safe and quiet under cron:

  */30 * * * * /home/s3/web.321.do/bin/321 recycle >> /tmp/321.do/recycle.log 2>&1

=cut
