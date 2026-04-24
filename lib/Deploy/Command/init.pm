package Deploy::Command::init;

use Mojo::Base 'Deploy::Command', -signatures;
use Path::Tiny qw(path);
use Mojo::File;

has description => 'Create a 321.yml manifest in the current repo';
has usage => sub ($self) { $self->extract_usage };

sub run ($self, @args) {
    if (-f '321.yml') {
        say "321.yml already exists. Edit it with:";
        say "  nano 321.yml";
        return;
    }

    unless (-d '.git') {
        die "Not a git repository. Run 321 init from the root of a git repo.\n";
    }

    # Infer what we can from the repo
    my $repo_url = $self->_git_remote();
    my $branch   = $self->_git_branch();
    my $dir_name = Mojo::File->new('.')->to_abs->basename;
    my $name     = $self->_guess_name($dir_name);
    my $entry    = $self->_guess_entry();

    my $repo_line = $repo_url
        ? "repo: $repo_url"
        : "# repo: git\@github.com:user/repo.git";

    my $entry_line = $entry
        ? "entry: $entry"
        : "entry: bin/app.pl";

    path('321.yml')->spew_utf8(<<"YAML");
# 321.yml - service manifest for $name
#
# 321 reads this file to know how to build, run, and deploy your app.
# Edit the values below, then run: 321 install $name

# === Service Identity ===

# Service name: <group>.<type> (e.g. love.web, zorda.api)
# This drives the ubic service tree, nginx config, and log file names.
name: $name

# Git clone URL - used by '321 install' to clone on remote servers
$repo_line

# Entry point - the Perl script 321 starts via hypnotoad or morbo
$entry_line

# Process runner: hypnotoad (production, zero-downtime restarts)
#                 morbo (development, auto-reload on file changes)
#                 script (plain perl script, no server framework)
runner: hypnotoad

# Perl version via perlbrew - omit to use system perl
perl: perl-5.42.0

# Health check endpoint - 321 hits this after deploy to verify the app is up
# Must respond with HTTP 200 to pass
# health: /health

# Git branch to deploy from (default: master)
branch: $branch

# System packages needed before cpanm (installed via sudo apt-get)
# apt_deps:
#   - libexpat1-dev
#   - libpng-dev
#   - libssl-dev

# === Targets ===
#
# Each top-level block (other than the fields above) is a deploy target.
# 'dev' = local development, 'live' = production server.
# You can add more: live2, staging, etc.

dev:
    host: $name.dev            # hostname for nginx + SSL (mkcert on dev)
    port: 8080                 # port the app listens on
    runner: morbo              # override runner for dev (auto-reload)

# Uncomment and fill in for production deploys:
# live:
#     ssh: ubuntu\@your-ec2-host.compute.amazonaws.com
#     ssh_key: ~/.ssh/kaizen-nige.pem
#     host: your-domain.com
#     port: 8080
#     runner: hypnotoad

# === Environment Variables ===
#
# env_required: keys the app MUST have to start.
#   Deploy is blocked if any are missing from secrets/<name>.env
#   Values here are descriptions, not the actual secrets.
#
# env_optional: keys with sensible defaults.
#   Only set these if you need to override the default.

# env_required:
#   DATABASE_URL: "Postgres connection string (e.g. postgresql://user:pass\@host/db)"
#   SECRET_KEY: "Session signing key"

# env_optional:
#   LOG_LEVEL:
#     default: info
#     desc: "debug | info | warn | error"
#   MOJO_MODE:
#     default: production
#     desc: "production | development"
YAML

    say "Created 321.yml for $name";
    say "";
    say "Inferred:";
    say "  name:   $name";
    say "  repo:   $repo_url" if $repo_url;
    say "  entry:  $entry" if $entry;
    say "  branch: $branch";

    # Add dev hostname to /etc/hosts if not already there
    my $dev_host = "$name.dev";
    my $hosts_file = path('/etc/hosts');
    if ($hosts_file->exists) {
        my $content = $hosts_file->slurp_utf8;
        if ($content =~ /\Q$dev_host\E/) {
            say "  hosts:  $dev_host (already in /etc/hosts)";
        } elsif (-w '/etc/hosts') {
            $hosts_file->append_utf8("127.0.0.1  $dev_host\n");
            say "  hosts:  added $dev_host to /etc/hosts";
        } else {
            say "";
            say "  Add to /etc/hosts (needs sudo):";
            say "    echo '127.0.0.1  $dev_host' | sudo tee -a /etc/hosts";
        }
    }

    say "";
    say "Next: review and edit, then install:";
    say "  nano 321.yml";
    say "  321 install $name";
}

sub _git_remote ($self) {
    my $url = `git remote get-url origin 2>/dev/null`;
    chomp $url;
    return $url || undef;
}

sub _git_branch ($self) {
    my $branch = `git rev-parse --abbrev-ref HEAD 2>/dev/null`;
    chomp $branch;
    return $branch || 'master';
}

sub _guess_name ($self, $dir_name) {
    # web.321.do -> 321.web, api.zorda.co -> zorda.api, love.honeywillow.com -> love.web
    if ($dir_name =~ /^(web|api|app)\.(.+?)(?:\.\w+)?$/) {
        return "$2.$1";
    }
    # love.honeywillow.com -> love.web
    if ($dir_name =~ /^([^.]+)\./) {
        return "$1.web";
    }
    return "$dir_name.web";
}

sub _guess_entry ($self) {
    # Look for common entry points
    for my $candidate (qw(bin/app.pl script/app bin/web.pl)) {
        return $candidate if -f $candidate;
    }
    # Check for any .pl file in bin/
    if (-d 'bin') {
        my @scripts = glob('bin/*.pl');
        return $scripts[0] if @scripts == 1;
    }
    # Check script/ dir
    if (-d 'script') {
        my @scripts = glob('script/*');
        @scripts = grep { -f $_ && -x $_ } @scripts;
        return $scripts[0] if @scripts == 1;
    }
    return undef;
}

1;

=head1 SYNOPSIS

  Usage: APPLICATION init

  Creates a well-commented 321.yml manifest in the current directory.
  Run from the root of a git repo.

  Infers what it can:
    - name from directory name (web.321.do -> 321.web)
    - repo from git remote origin
    - branch from current git branch
    - entry from common locations (bin/app.pl, script/*)

  321 init               # create 321.yml
  nano 321.yml           # review and edit
  321 install myapp.web  # install the service

=cut
