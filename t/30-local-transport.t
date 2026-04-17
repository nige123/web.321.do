use strict;
use warnings;
use Test::More;
use Path::Tiny qw(tempdir path);
use Deploy::Local;

# 1. run: simple command
{
    my $local = Deploy::Local->new;
    my $result = $local->run('echo hello');
    ok $result->{ok}, 'run: echo hello returns ok';
    like $result->{output}, qr/hello/, 'run: output contains hello';
    is $result->{exit_code}, 0, 'run: exit_code is 0';
}

# 2. run: failing command
{
    my $local = Deploy::Local->new;
    my $result = $local->run('false');
    ok !$result->{ok}, 'run: false returns not ok';
    isnt $result->{exit_code}, 0, 'run: exit_code is non-zero';
}

# 3. run: timeout
{
    my $local = Deploy::Local->new;
    my $result = $local->run('sleep 10', timeout => 1);
    ok !$result->{ok}, 'run: timed-out command returns not ok';
    like $result->{output}, qr/timed? ?out/i, 'run: output mentions timeout';
}

# 4. run_in_dir: runs in specified directory
{
    my $local = Deploy::Local->new;
    my $result = $local->run_in_dir('/tmp', 'pwd');
    ok $result->{ok}, 'run_in_dir: ok';
    # /tmp may be a symlink on some systems; check it resolves to /tmp path
    like $result->{output}, qr{/tmp}, 'run_in_dir: output contains /tmp';
}

# 5. run_steps: aborts on failure
{
    my $local = Deploy::Local->new;
    my @steps = (
        { cmd => 'echo step1', label => 'Step 1' },
        { cmd => 'false',      label => 'Step 2 (fails)' },
        { cmd => 'echo step3', label => 'Step 3 (should not run)' },
    );
    my $result = $local->run_steps(\@steps);
    ok !$result->{ok}, 'run_steps: not ok when a step fails';
    is scalar @{ $result->{steps} }, 2, 'run_steps: stops after second step';
    ok $result->{steps}[0]{ok},  'run_steps: first step ok';
    ok !$result->{steps}[1]{ok}, 'run_steps: second step not ok';
}

# 6. upload: copies file between temp dirs
{
    my $local = Deploy::Local->new;
    my $src_dir = tempdir(CLEANUP => 1);
    my $dst_dir = tempdir(CLEANUP => 1);

    my $src_file = path($src_dir, 'hello.txt');
    $src_file->spew_utf8("hello world\n");

    my $dst_file = path($dst_dir, 'hello.txt');

    my $result = $local->upload("$src_file", "$dst_file");
    ok $result->{ok}, 'upload: returns ok';
    ok $dst_file->exists, 'upload: destination file exists';
    is $dst_file->slurp_utf8, "hello world\n", 'upload: contents match';
}

done_testing;
