package Deploy::Config;

use Mojo::Base -base, -signatures;
use Path::Tiny qw(path);
use Mojo::File qw(curfile);
use Deploy::Manifest;

has 'app_home'   => sub { $ENV{APP_HOME} // curfile->dirname->dirname->dirname };
has 'scan_dir'   => sub { $ENV{SCAN_DIR} // '/home/s3' };
has 'target'     => 'dev';
has '_services'  => sub ($self) { $self->_load_all };
has '_mtimes'    => sub { {} };

sub reload ($self) {
    $self->_services($self->_load_all);
    return $self;
}

sub _check_reload ($self) {
    my $base = path($self->scan_dir);
    return unless $base->exists;
    for my $dir (sort $base->children) {
        next unless $dir->is_dir;
        my $file = $dir->child('321.yml');
        next unless $file->exists;
        my $mtime = $file->stat->mtime;
        my $prev  = $self->_mtimes->{"$file"} // 0;
        if ($mtime > $prev) {
            $self->reload;
            return;
        }
    }
}

sub _load_all ($self) {
    my $base = path($self->scan_dir);
    return {} unless $base->exists;

    my %services;
    my %mtimes;
    for my $dir (sort $base->children) {
        next unless $dir->is_dir;
        my $file = $dir->child('321.yml');
        $mtimes{"$file"} = $file->stat->mtime if $file->exists;
        my $manifest = Deploy::Manifest->load($dir);
        next unless $manifest;
        $services{ $manifest->{name} } = $manifest;

        # Workers inherit everything from the parent manifest, then override
        # the bits that make them a worker (own name/entry, no health probe).
        my $workers = $manifest->{workers} // {};
        my ($group) = split /\./, $manifest->{name}, 2;
        for my $worker_name (keys %$workers) {
            my $full_name = "$group.$worker_name";
            $services{$full_name} = {
                %$manifest,
                name    => $full_name,
                entry   => $workers->{$worker_name}{cmd},
                runner  => 'script',
                health  => undef,
                workers => undef,
                _parent => $manifest->{name},
            };
        }
    }
    $self->_mtimes(\%mtimes);
    return \%services;
}

sub services ($self) {
    $self->_check_reload;
    return $self->_services;
}

sub service ($self, $name) {
    $self->_check_reload;
    my $manifest = $self->_services->{$name};
    return undef unless $manifest;
    return $self->_resolve($name, $manifest);
}

sub _resolve ($self, $name, $manifest) {
    my $target_name = $self->target;
    my $target = $manifest->{targets}{$target_name} // {};

    my $is_worker = exists $manifest->{_parent};
    my $runner = $is_worker ? 'script' : ($target->{runner} // $manifest->{runner} // 'hypnotoad');

    # Mode is a property of the target, not the runner. Workers force runner
    # to 'script' so the old runner-based heuristic baked MOJO_MODE=production
    # into dev workers and they'd try to reach the live DB.
    my $mode = ($target_name eq 'dev') ? 'development' : 'production';

    # Where hypnotoad keeps its manager pid. Defaults beside the entry script
    # (hypnotoad's own default); a manifest pid_file (target wins) must mirror
    # any pid_file the app sets in its hypnotoad config, since 321 cannot pass
    # it on the command line.
    my $pid_file = $is_worker ? undef
        : $target->{pid_file} // $manifest->{pid_file} // do {
              my ($bindir) = ($manifest->{entry} // '') =~ m{^(.*)/};
              my $sub = (defined $bindir && length $bindir) ? "/$bindir" : '';
              "$manifest->{repo}$sub/hypnotoad.pid";
          };

    return {
        name         => $name,
        repo         => $manifest->{repo},
        branch       => $manifest->{branch} // 'master',
        bin          => $manifest->{entry},
        mode         => $mode,
        runner       => $runner,
        port         => $is_worker ? undef : $target->{port},
        host         => $target->{host} // 'localhost',
        apt_deps     => $manifest->{apt_deps} // [],
        health       => $manifest->{health} // '/health',
        logs         => {
            stdout => "/tmp/$name.stdout.log",
            stderr => "/tmp/$name.stderr.log",
            ubic   => "/tmp/$name.ubic.log",
        },
        ($is_worker            ? (is_worker => 1)                    : ()),
        ($pid_file             ? (pid_file => $pid_file)             : ()),
        ($manifest->{test}     ? (test     => $manifest->{test})     : ()),
        ($manifest->{favicon}  ? (favicon  => $manifest->{favicon})  : ()),
        ($manifest->{gobin}    ? (gobin    => $manifest->{gobin})    : ()),
        (exists $manifest->{force_https} ? (force_https => $manifest->{force_https}) : ()),
        (exists $target->{client_max_body_size}
            ? (client_max_body_size => $target->{client_max_body_size})
            : (exists $manifest->{client_max_body_size}
                ? (client_max_body_size => $manifest->{client_max_body_size})
                : ())),
        (($target->{aliases} // $manifest->{aliases}) ? (aliases => $target->{aliases} // $manifest->{aliases}) : ()),
        ($target->{ssh}        ? (ssh      => $target->{ssh})        : ()),
        ($target->{ssh_key}    ? (ssh_key  => $target->{ssh_key})    : ()),
        ($target->{docs}       ? (docs     => $target->{docs})       : ()),
        ($target->{admin}      ? (admin    => $target->{admin})      : ()),
        ($manifest->{perl}     ? (perlbrew => $manifest->{perl})     : ()),
        ($target->{env}        ? (env      => $target->{env})        : (env => {})),
    };
}

sub service_names ($self) {
    return [ sort keys %{ $self->_services } ];
}

sub workers_of ($self, $name) {
    $self->_check_reload;
    my $manifest = $self->_services->{$name};
    return [] unless $manifest;
    return [] if exists $manifest->{_parent};   # this entry is a worker, not a main
    my $workers = $manifest->{workers} // {};
    my ($group) = split /\./, $name, 2;
    return [ map { "$group.$_" } sort keys %$workers ];
}

sub service_raw ($self, $name) {
    return $self->_services->{$name};
}

sub dev_hostnames ($self) {
    my %seen;
    my @hosts;
    for my $name (@{ $self->service_names }) {
        my $manifest = $self->_services->{$name};
        my $dev = $manifest->{targets}{dev} or next;
        my $h = $dev->{host} or next;
        next if $h eq 'localhost';
        push @hosts, $h unless $seen{$h}++;
    }
    return [ sort @hosts ];
}

1;
