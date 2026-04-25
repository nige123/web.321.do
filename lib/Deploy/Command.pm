package Deploy::Command;

use Mojo::Base 'Mojolicious::Command', -signatures;

sub config  ($self) { $self->app->config_obj }
sub ubic    ($self) { $self->app->ubic_mgr_obj }
sub nginx   ($self) { $self->app->nginx_mgr_obj }
sub svc_mgr ($self) { $self->app->svc_mgr_obj }

sub resolve_service ($self, $input) {
    my @names = @{ $self->config->service_names };

    return $input if grep { $_ eq $input } @names;

    # Prefix match
    my @m = grep { index(lc $_, lc $input) == 0 } @names;
    return $m[0] if @m == 1;

    # Substring match
    @m = grep { index(lc $_, lc $input) >= 0 } @names;
    return $m[0] if @m == 1;

    return @m if @m > 1 && wantarray;

    if (@m > 1) {
        die "Ambiguous: '$input' matches: " . join(', ', @m) . "\n";
    }

    # Not found — scaffold 321.yml if we're in a repo dir without one
    if (-d '.git' && ! -f '321.yml') {
        require Cwd;
        my $cwd = Cwd::getcwd();
        say "Unknown service: $input";
        say "Known services: " . join(', ', @names) if @names;
        say "";
        say "Creating 321.yml in $cwd ...";
        $self->_write_boilerplate($input);
        say "";
        say "Next: edit 321.yml then re-run your command:";
        say "  nano 321.yml";
        say "  321 install $input";
        exit 0;
    }

    my $msg = "Unknown service: $input\n";
    $msg .= "Known services: " . join(', ', @names) . "\n" if @names;

    # If we're in a repo with a 321.yml, hint at the actual service name
    my $local = $self->_infer_service;
    if ($local) {
        $msg .= "\nThis repo's service is '$local'. Did you mean that?\n";
    } else {
        $msg .= "\nTo register a new service, create a 321.yml in its repo:\n";
        $msg .= "  cd /home/s3/<repo> && 321 install $input\n";
    }
    die $msg;
}

sub parse_target ($self, @args) {
    if (!@args) {
        # No args — try to infer service from cwd
        my $svc = $self->_infer_service;
        return ($svc, 'dev') if $svc;
        return (undef, 'dev');
    }
    if (@args == 1) {
        # Is it a known target name? If so, infer service from cwd
        if ($self->_is_target_name($args[0])) {
            my $svc = $self->_infer_service;
            return ($svc, $args[0]) if $svc;
            return (undef, $args[0]);
        }
        return ($args[0], 'dev');
    }
    my ($svc_input, $target_input) = @args;
    return ($svc_input, $target_input);
}

sub _infer_service ($self) {
    my $manifest_file = Mojo::File->new('321.yml');
    return undef unless -f $manifest_file;
    require YAML::XS;
    my $raw = YAML::XS::LoadFile($manifest_file->to_string);
    return $raw->{name} if ref $raw eq 'HASH' && $raw->{name};
    return undef;
}

sub _is_target_name ($self, $name) {
    for my $svc_name (@{ $self->config->service_names }) {
        my $raw = $self->config->service_raw($svc_name);
        return 1 if exists $raw->{targets}{$name};
    }
    return 0;
}

sub transport_for ($self, $name, $target) {
    require Deploy::Transport;
    my $cfg = $self->config;
    my $old_target = $cfg->target;
    $cfg->target($target);
    my $svc = $cfg->service($name);
    $cfg->target($old_target);
    return undef unless $svc;
    return Deploy::Transport->for_target($svc, perlbrew => $svc->{perlbrew});
}

sub _write_boilerplate ($self, $name) {
    require Path::Tiny;
    Path::Tiny::path('321.yml')->spew_utf8(<<"YAML");
# 321.yml - service manifest for $name
#
# This file tells 321 how to run your app.
# Edit the values below, then run: 321 install $name

# Service identity
name: $name

# Git clone URL (used by 321 install to clone on remote servers)
# repo: git\@github.com:user/repo.git

# Entry point - the script 321 starts via hypnotoad/morbo
entry: bin/app.pl

# Default process runner: hypnotoad (production) or morbo (dev, auto-reload)
runner: hypnotoad

# Perl version managed by perlbrew (omit if using system perl)
perl: perl-5.42.0

# Health check path (GET, must return 200)
# health: /health

# Git branch to deploy from
# branch: main

# === Targets ===
# Each target defines where and how the service runs.
# 'dev' runs locally, 'live' runs on a remote server via SSH.

dev:
    host: $name.dev
    port: 8080
    runner: morbo

# live:
#     ssh: ubuntu\@your-ec2-host.compute.amazonaws.com
#     ssh_key: ~/.ssh/your-key.pem
#     host: your-domain.com
#     port: 8080
#     runner: hypnotoad

# === Environment Variables ===

# Variables the app requires to start (deploy blocked if missing)
# env_required:
#   DATABASE_URL: "Postgres connection string"

# Variables with sensible defaults (optional to set)
# env_optional:
#   LOG_LEVEL:
#     default: info
#     desc: "debug | info | warn | error"
YAML
}

sub check_port ($self, $port, $transport) {
    return 0 unless $port && $port ne '?';
    my $r = $transport->run(
        "curl -sf -o /dev/null --connect-timeout 2 http://127.0.0.1:$port/",
        timeout => 5,
    );
    return $r->{ok} ? 1 : 0;
}

sub service_url ($self, $svc) {
    my $host = $svc->{host} // 'localhost';
    my $port = $svc->{port} // '?';
    return $host ne 'localhost' ? "https://$host/" : "http://localhost:$port/";
}

sub target_flag ($self, $target) {
    return $target ne 'dev' ? " $target" : "";
}

sub diagnose_stderr ($self, $transport, $name, $target) {
    my $logs = $transport->run("tail -20 /tmp/$name.stderr.log 2>/dev/null");
    my $stderr = $logs->{output} // '';
    my $flag = $self->target_flag($target);

    if ($stderr =~ /Can't locate (\S+\.pm).*you may need to install the (\S+) module/s) {
        return ("\e[33mMissing module: $2\e[0m", "321 install $name$flag");
    }
    if ($stderr =~ /Can't locate (\S+\.pm)/s) {
        (my $mod = $1) =~ s/\//::/g; $mod =~ s/\.pm$//;
        return ("\e[33mMissing module: $mod\e[0m", "321 install $name$flag");
    }
    return ();
}

# Deref ubic step success (scalar ref \1/\0 or plain bool)
sub step_ok ($self, $step) {
    return ref $step->{success} ? ${ $step->{success} } : $step->{success};
}

sub print_steps ($self, $r) {
    for my $step (@{ $r->{data}{steps} // [] }) {
        my $ok = $self->step_ok($step);
        printf "  [%s] %s\n", ($ok ? 'OK' : 'FAIL'), $step->{step};
    }
}

sub print_failure ($self, $transport, $name, $target, $message = undef) {
    say "  $message" if $message;
    my @diag = $self->diagnose_stderr($transport, $name, $target);
    if (@diag) {
        say "  $diag[0]";
        say "  Fix: $diag[1]";
    }

    # Show last 30 lines of stderr
    my $logs = $transport->run("tail -30 /tmp/$name.stderr.log 2>/dev/null");
    if ($logs->{output} && $logs->{output} =~ /\S/) {
        say "";
        say "  --- stderr (last 30 lines) ---";
        for my $line (split /\n/, $logs->{output}) {
            say "  $line";
        }
    } else {
        say "  No stderr log at /tmp/$name.stderr.log";
    }
}

1;
