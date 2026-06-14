use strict;
use warnings;
use Test::More;
use Deploy::Command::recycle;
my $CMD = "Deploy::Command::recycle";

# `321 recycle` restarts local dev services whose process tree has grown past
# a memory threshold - the permanent fix for morbo never recycling its worker.
# The measurable logic is pure: tree-RSS summing from a ps snapshot, and
# picking which services to bounce (with parent/worker dedup).

# --- tree_rss_mb: sum RSS of a pid and all its descendants ------------------

subtest 'tree_rss_mb sums the root pid and its descendants' => sub {
    # ps -eo pid,ppid,rss (rss in KB)
    my $ps = <<'PS';
    PID   PPID   RSS
      1      0  1000
    100      1  50000
    101    100 900000
    102    101 200000
    200      1  70000
PS
    # 100 (morbo parent) + 101 (worker) + 102 (grandchild) = 1150000 KB
    is $CMD->tree_rss_mb($ps, 100), 1123,
        'root + child + grandchild summed, KB -> MB (int)';
};

subtest 'tree_rss_mb with no children returns own RSS only' => sub {
    my $ps = <<'PS';
    PID   PPID   RSS
    200      1  70000
    300      1  80000
PS
    is $CMD->tree_rss_mb($ps, 200), 68, 'just own RSS';
};

subtest 'tree_rss_mb returns 0 for an unknown pid' => sub {
    my $ps = "    PID   PPID   RSS\n    200      1  70000\n";
    is $CMD->tree_rss_mb($ps, 999), 0, 'unknown pid -> 0';
};

# --- pick_recyclable: threshold filter + parent/worker dedup ----------------

subtest 'pick_recyclable keeps only services over the threshold' => sub {
    my $picked = $CMD->pick_recyclable(
        [
            { name => 'demo.web',  rss_mb => 1500 },
            { name => 'solo.web',  rss_mb => 200 },
            { name => 'other.web', rss_mb => 1001 },
        ],
        1000,
    );
    is_deeply [ map { $_->{name} } @$picked ], ['demo.web', 'other.web'],
        'over-threshold services picked, sorted by name';
};

subtest 'pick_recyclable drops a worker when its parent is also picked' => sub {
    # Restarting the parent cascades to workers - bouncing both would
    # restart the worker twice.
    my $picked = $CMD->pick_recyclable(
        [
            { name => 'demo.web',    rss_mb => 1500 },
            { name => 'demo.minion', rss_mb => 1200, parent => 'demo.web' },
        ],
        1000,
    );
    is_deeply [ map { $_->{name} } @$picked ], ['demo.web'],
        'worker folded into its parent restart';
};

subtest 'pick_recyclable keeps a fat worker whose parent is healthy' => sub {
    my $picked = $CMD->pick_recyclable(
        [
            { name => 'demo.web',    rss_mb => 300 },
            { name => 'demo.minion', rss_mb => 1200, parent => 'demo.web' },
        ],
        1000,
    );
    is_deeply [ map { $_->{name} } @$picked ], ['demo.minion'],
        'only the worker is bounced; healthy parent untouched';
};

subtest 'pick_recyclable returns [] when everything is healthy' => sub {
    my $picked = $CMD->pick_recyclable(
        [ { name => 'demo.web', rss_mb => 300 } ],
        1000,
    );
    is_deeply $picked, [], 'nothing to do';
};

done_testing;
