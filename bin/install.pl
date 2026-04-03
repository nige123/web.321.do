#!/usr/bin/env perl

# install.pl — first-time setup for 321.do
# Usage: sudo perl bin/install.pl

use v5.18;
use feature 'say';
use File::Copy;
use File::Path qw(make_path);

my $domain     = '321.do';
my $app_port   = 9999;
my $app_dir    = '/home/s3/321.do';
my $perl_ver   = 'perl-5.42.1';
my $run_user   = (getpwuid((stat $app_dir)[4]))[0] // $ENV{SUDO_USER} // 'ubuntu';
my $user_home  = (getpwnam($run_user))[7] // "/home/$run_user";
my $nginx_conf = "/etc/nginx/sites-available/$domain";
my $nginx_link = "/etc/nginx/sites-enabled/$domain";
my $ubic_src   = "$app_dir/ubic/service/321";
my $ubic_dest  = "$user_home/ubic/service/321";
my $perlbrew   = "su - $run_user -c 'perlbrew exec --with $perl_ver";

die "Must run as root (sudo)\n" unless $> == 0;

say "=== 321.do installer ===\n";

# --- Step 1: Ensure perlbrew and required Perl version ---
say "--- Checking perlbrew and Perl $perl_ver ---";

my $has_perlbrew = system("su - $run_user -c 'which perlbrew'") == 0;
unless ($has_perlbrew) {
    say "Installing perlbrew...";
    system("su - $run_user -c 'curl -L https://install.perlbrew.pl | bash'") == 0
        or die "perlbrew installation failed\n";
}

my $has_perl = system("su - $run_user -c 'perlbrew list' | grep -q '$perl_ver'") == 0;
unless ($has_perl) {
    say "Installing $perl_ver (this may take a while)...";
    system("su - $run_user -c 'perlbrew install $perl_ver'") == 0
        or die "Failed to install $perl_ver\n";
}

# Ensure cpanm is available
system("su - $run_user -c 'perlbrew install-cpanm'") == 0
    or warn "cpanm install warning (may already exist)\n";

# --- Step 2: Install Perl dependencies ---
say "--- Installing Perl dependencies ---";
system("$perlbrew cpanm --installdeps $app_dir'") == 0
    or die "cpanm failed\n";

# --- Step 3: Create deploy token if missing ---
my $token_file = "$app_dir/deploy_token.txt";
unless (-f $token_file) {
    say "--- Generating deploy token ---";
    chomp(my $token = `openssl rand -hex 32`);
    open my $fh, '>', $token_file or die "Cannot write $token_file: $!\n";
    print $fh $token;
    close $fh;
    chmod 0600, $token_file;
    say "Token saved to $token_file";
    say "Token: $token";
}

# --- Step 4: Write nginx config ---
say "--- Writing nginx config ---";

my $nginx = <<"NGINX";
server {
    listen 80;
    server_name $domain;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name $domain;

    ssl_certificate     /etc/letsencrypt/live/$domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$domain/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    access_log /var/log/nginx/${domain}.access.log;
    error_log  /var/log/nginx/${domain}.error.log;

    location / {
        proxy_pass http://127.0.0.1:$app_port;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
NGINX

open my $fh, '>', $nginx_conf or die "Cannot write $nginx_conf: $!\n";
print $fh $nginx;
close $fh;
say "Wrote $nginx_conf";

# --- Step 5: Symlink to sites-enabled ---
if (-l $nginx_link) {
    unlink $nginx_link;
}
symlink $nginx_conf, $nginx_link
    or die "Cannot symlink $nginx_link -> $nginx_conf: $!\n";
say "Symlinked $nginx_link";

# --- Step 6: SSL cert via certbot ---
unless (-f "/etc/letsencrypt/live/$domain/fullchain.pem") {
    say "--- Obtaining SSL certificate ---";
    system("certbot certonly --nginx -d $domain --non-interactive --agree-tos -m admin\@$domain") == 0
        or warn "certbot failed — run manually: sudo certbot certonly --nginx -d $domain\n";
}
else {
    say "SSL cert already exists";
}

# --- Step 7: Test and reload nginx ---
say "--- Testing nginx config ---";
system('nginx -t') == 0
    or die "nginx config test failed\n";

say "--- Reloading nginx ---";
system('systemctl reload nginx') == 0
    or die "nginx reload failed\n";

# --- Step 8: Ubic service symlink ---
say "--- Setting up ubic service ---";
make_path($ubic_dest) unless -d $ubic_dest;
my $ubic_link = "$ubic_dest/web";
if (-l $ubic_link) {
    unlink $ubic_link;
}
symlink "$ubic_src/web", $ubic_link
    or die "Cannot symlink $ubic_link -> $ubic_src/web: $!\n";
say "Symlinked $ubic_link";

# Ensure Ubic is installed
system("$perlbrew cpanm Ubic Ubic::Service::SimpleDaemon'") == 0
    or die "Failed to install Ubic modules\n";

# --- Step 9: Start the app via ubic ---
say "--- Starting 321.do via ubic ---";
system("su - $run_user -c 'ubic start 321.web'") == 0
    or die "ubic start failed\n";

say "\n=== 321.do installed ===";
say "  https://$domain";
say "  Perl:  $perl_ver (perlbrew)";
say "  App running on port $app_port (managed by ubic)";
say "  Nginx proxying 443 -> $app_port";
say "";
say "  ubic start   321.web";
say "  ubic stop    321.web";
say "  ubic restart 321.web";
say "  ubic status  321.web";
