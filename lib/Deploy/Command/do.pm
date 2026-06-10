package Deploy::Command::do;

use Mojo::Base 'Deploy::Command', -signatures;

has description => 'Run a service Mojolicious subcommand at a target';
has usage => sub ($self) { $self->extract_usage };

sub run ($self, @argv) {
    my $p = $self->parse_args(@argv);

    $self->config->target($p->{target});

    # Resolve the service: explicit token, else infer from the cwd 321.yml.
    my $svc_input = $p->{service} // $self->_infer_service;
    die "Run inside a service repo, or name the service:\n  321 do <service> <target> <subcommand> [args]\n"
        unless $svc_input;
    my $name = $self->resolve_service($svc_input);

    my $svc = $self->config->service($name);
    die "Unknown service: $name\n" unless $svc;
    die "$name has no entry script (workers can't take subcommands)\n" unless $svc->{bin};

    my $transport = $self->transport_for($name, $p->{target});

    # Make sure the repo is actually there before we try to run in it.
    my $check = $transport->run("test -d $svc->{repo}/.git && echo OK");
    unless (($check->{output} // '') =~ /OK/) {
        die "Repo not found at $svc->{repo} on $p->{target} - run '321 install $name "
          . "$p->{target}' first\n";
    }

    my $cmd = $self->build_command($svc, $p->{subcmd}, $p->{args});

    # Show exactly what runs and where before handing over the terminal.
    my $where = $svc->{ssh} ? " on $svc->{ssh}" : "";
    my $argline = join ' ', $p->{subcmd}, @{ $p->{args} };
    say "\e[36m-> $p->{target} $name:\e[0m perl $svc->{bin} $argline$where";

    my $r = $transport->exec_in_dir($svc->{repo}, $cmd);
    exit($r->{exit_code} // 0);
}

# parse_args(@argv) - split into { service, target, subcmd, args }.
#
# The target is the first argument that names a known target (dev/live/…).
# Tokens before it are the (optional, at most one) service; tokens after it are
# the subcommand and its args. With no target token we default to 'dev' and the
# whole list is the subcommand + args (service then comes from the cwd repo).
sub parse_args ($self, @argv) {
    die $self->usage unless @argv;

    my $ti;
    for my $i (0 .. $#argv) {
        next if $argv[$i] eq 'all';   # 'all' is a fleet selector, not a do target
        if ($self->_is_target_name($argv[$i])) { $ti = $i; last }
    }

    my ($service, $target, @rest);
    if (defined $ti) {
        $target  = $argv[$ti];
        $service = $ti > 0 ? $argv[$ti - 1] : undef;   # at most one service token
        @rest    = @argv[$ti + 1 .. $#argv];
    } else {
        $target  = 'dev';
        @rest    = @argv;
    }

    die "No subcommand given.\n" . $self->usage unless @rest;
    my $subcmd = shift @rest;
    return { service => $service, target => $target, subcmd => $subcmd, args => [@rest] };
}

# build_command($svc, $subcmd, \@args) - the shell command that reproduces the
# service's runtime (perl version + env + repo-local libs) and invokes the
# Mojolicious subcommand. Run from inside the repo by the transport.
sub build_command ($self, $svc, $subcmd, $args) {
    my $perl = $svc->{perlbrew} // 'perl-5.42.0';
    my $repo = $svc->{repo};

    my %env = %{ $svc->{env} // {} };
    $env{MOJO_MODE} //= $svc->{mode} // 'production';
    $env{PERL5LIB}   = "$repo/local/lib/perl5";

    my $env_str = join ' ', map { "$_=" . _shq($env{$_}) } sort keys %env;

    # -MConfig preloads core Config before the app's own startup. Apps commonly
    # unshift every subdir of their bundled local/lib/perl5 onto @INC in a BEGIN
    # block; that can shadow core Config.pm (e.g. via HTTP/Config.pm) so a later
    # `use Config` in File::Copy/Mojo::File fails with "%Config requires explicit
    # package name". The supervised daemon dodges this only because hypnotoad
    # loads Config early - preloading it here reproduces that same load order.
    my $invoke = join ' ', 'perl', '-MConfig', $svc->{bin}, $subcmd, map { _shq($_) } @$args;

    return "perlbrew exec --with $perl env $env_str $invoke";
}

# Single-quote for the shell: wrap in '…', escaping embedded single quotes.
sub _shq ($val) {
    $val = '' unless defined $val;
    $val =~ s/'/'\\''/g;
    return "'$val'";
}

1;

=head1 SYNOPSIS

  Usage: APPLICATION do [service] <target> <subcommand> [args...]

  Run one of a service app's own Mojolicious subcommands in that service's
  real runtime environment (right perl, MOJO_MODE/MOJO_CONFIG, repo-local
  libs), locally on dev or over SSH on live. Interactive - prompts work and
  output streams live; exits with the subcommand's exit code.

  321 do live create_admin nige@123.do   # cwd repo, on live
  321 do petals.web live create_admin a   # explicit service
  321 do eval 'say 1+1'                    # cwd repo, on dev (default target)

=cut
