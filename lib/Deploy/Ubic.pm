package Deploy::Ubic;

use Mojo::Base -base, -signatures;
use Path::Tiny qw(path);

has 'config';  # Deploy::Config instance
has 'log';     # Mojo::Log instance (optional)

sub generate_all ($self) {
    my @results;
    for my $name (@{ $self->config->service_names }) {
        push @results, $self->generate($name);
    }
    return \@results;
}

sub generate ($self, $name) {
    my $svc = $self->config->service($name);
    return { name => $name, status => 'error', message => "Unknown service: $name" } unless $svc;

    my $content = $self->_render_service_file($name, $svc);
    my $file    = $self->_ubic_file_path($svc, $name);

    $file->parent->mkpath;
    $file->spew_utf8($content);
    $file->chmod(0644);

    $self->log->info("Generated ubic service file: $file") if $self->log;
    return { name => $name, status => 'ok', path => "$file" };
}

sub install_symlinks ($self) {
    my $ubic_home = path($ENV{HOME}, 'ubic', 'service');
    my @results;

    for my $name (@{ $self->config->service_names }) {
        my $svc = $self->config->service($name);
        next unless $svc;

        my $source = $self->_ubic_file_path($svc, $name);
        next unless $source->exists;

        my ($group, $svc_name) = split /\./, $name, 2;
        my $dest = $ubic_home->child($group, $svc_name);

        $dest->parent->mkpath;

        # Remove existing symlink or file
        if (-l $dest || $dest->exists) {
            unlink $dest;
        }

        symlink($source->absolute, $dest)
            or warn "Failed to symlink $source -> $dest: $!\n";

        $self->log->info("Symlinked $dest -> $source") if $self->log;
        push @results, { name => $name, source => "$source", dest => "$dest" };
    }

    return \@results;
}

sub _render_service_file ($self, $name, $svc) {
    my $bin_cmd = $self->_build_bin_cmd($svc);
    my $cwd     = $svc->{repo};
    my $logs    = $svc->{logs} // {};

    my $stdout   = $logs->{stdout}   // "/tmp/$name.stdout.log";
    my $stderr   = $logs->{stderr}   // "/tmp/$name.stderr.log";
    my $ubic_log = $logs->{ubic}     // "/tmp/$name.ubic.log";

    my $mode    = $svc->{mode} // 'production';
    my $runner  = $svc->{runner} // 'hypnotoad';

    # bin_cmd contains shell-quoted env values with embedded single quotes.
    # Escape backslashes and single quotes so the string survives being
    # interpolated into a Perl single-quoted literal in the rendered file.
    my $bin_literal = $bin_cmd =~ s/([\\'])/\\$1/gr;

    return <<"END_UBIC";
use Ubic::Service::SimpleDaemon;

my \$LOG_ROOT = '/tmp';

# $name ($mode via $runner) — generated from services.yml
Ubic::Service::SimpleDaemon->new(
    cwd         =>  '$cwd',
    bin         =>  '$bin_literal',
    stdout      =>  '$stdout',
    stderr      =>  '$stderr',
    ubic_log    =>  '$ubic_log',
);
END_UBIC
}

sub _build_bin_cmd ($self, $svc) {
    my $runner   = $svc->{runner} // 'hypnotoad';
    my $perlbrew = $svc->{perlbrew} // 'perl-5.42.0';
    my $repo     = $svc->{repo};
    my $bin      = "$repo/$svc->{bin}";
    my $port     = $svc->{port};

    # Build env var prefix
    my $env = $svc->{env} // {};
    my $secrets = $self->config->load_secrets($svc->{name});
    my %all_env = (%$env, %$secrets);
    # Drop empty values — emitting VAR='' breaks the outer single-quoted bin
    # string and is equivalent to 'unset' for the app anyway.
    delete $all_env{$_} for grep { !defined $all_env{$_} || !length $all_env{$_} } keys %all_env;

    # Point the runtime at the repo's own local::lib tree (populated by
    # `cpanm -L local/ --installdeps .` during deploy).
    $all_env{PERL5LIB} = "$repo/local/lib/perl5";
    $all_env{PATH}     = "$repo/local/bin:" . ($ENV{PATH} // '/usr/local/bin:/usr/bin:/bin');

    my $env_str = '';
    if (%all_env) {
        $env_str = 'env ' . join(' ',
            map { "$_=" . _shell_quote($all_env{$_}) } sort keys %all_env
        ) . ' ';
    }

    if ($runner eq 'morbo') {
        return "perlbrew exec --with $perlbrew ${env_str}morbo -l http://127.0.0.1:$port $bin";
    }

    # hypnotoad -f — foreground, required by ubic SimpleDaemon
    return "perlbrew exec --with $perlbrew ${env_str}hypnotoad -f $bin";
}

sub _shell_quote ($val) {
    return "''" unless defined $val && length $val;
    $val =~ s/'/'\\''/g;
    return "'$val'";
}

sub _ubic_file_path ($self, $svc, $name) {
    my ($group, $svc_name) = split /\./, $name, 2;
    return path($svc->{repo}, 'ubic', 'service', $group, $svc_name);
}

1;
