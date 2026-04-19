# EC2 Dev Instance Setup — 321.dev

Provision a fresh EC2 instance to run `321.do` in dev mode (`dev.321.do` / `321.do.dev`).

**Target:** Ubuntu 24.04 LTS on EC2 (t3.small or larger — perlbrew compile needs RAM)
**User:** `s3` (non-root, with sudo)
**Domain:** `321.do.dev` (or whatever dev hostname is configured)

---

## Phase 1: EC2 + OS baseline

These steps are run once, manually or via user-data script.

### 1.1 Launch EC2

- AMI: Ubuntu 24.04 LTS (HVM, SSD)
- Instance type: `t3.small` (2 vCPU, 2 GB — enough for perlbrew compile)
- Storage: 20 GB gp3
- Security group: open ports 22 (SSH), 80 (HTTP), 443 (HTTPS)
- Key pair: your SSH key

### 1.2 Create the `s3` user

```bash
sudo adduser s3 --disabled-password --gecos ""
sudo usermod -aG sudo s3
# Copy SSH authorized_keys
sudo mkdir -p /home/s3/.ssh
sudo cp ~/.ssh/authorized_keys /home/s3/.ssh/
sudo chown -R s3:s3 /home/s3/.ssh
```

### 1.3 System packages

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y \
    build-essential \
    curl \
    git \
    nginx \
    certbot \
    libnss3-tools \
    libssl-dev \
    zlib1g-dev \
    age \
    jq
```

### 1.4 Install mkcert (dev SSL)

```bash
# Install mkcert from binary (apt version may be old)
curl -JLO "https://dl.filippo.io/mkcert/latest?for=linux/amd64"
chmod +x mkcert-v*-linux-amd64
sudo mv mkcert-v*-linux-amd64 /usr/local/bin/mkcert

# Install the local CA (as s3 user)
sudo -u s3 mkcert -install
```

### 1.5 Install SOPS

```bash
curl -LO https://github.com/getsops/sops/releases/download/v3.9.4/sops-v3.9.4.linux.amd64
chmod +x sops-v3.9.4.linux.amd64
sudo mv sops-v3.9.4.linux.amd64 /home/s3/bin/sops
sudo chown s3:s3 /home/s3/bin/sops
```

Ensure `~/bin` is on PATH — add to `/home/s3/.bashrc`:

```bash
export PATH="$HOME/bin:$PATH"
```

### 1.6 Copy age key

The SOPS-encrypted service YAMLs need the age private key. Copy it from the existing machine:

```bash
# On existing machine:
scp /home/s3/.config/sops/age/keys.txt s3@NEW_HOST:/home/s3/.config/sops/age/keys.txt

# Or create the dir and paste it manually:
sudo -u s3 mkdir -p /home/s3/.config/sops/age
# ... transfer keys.txt securely
sudo chmod 600 /home/s3/.config/sops/age/keys.txt
```

---

## Phase 2: Perlbrew + Perl

All steps as user `s3`.

```bash
sudo -iu s3
```

### 2.1 Install perlbrew

```bash
curl -L https://install.perlbrew.pl | bash
echo 'source ~/perl5/perlbrew/etc/bashrc' >> ~/.bashrc
source ~/perl5/perlbrew/etc/bashrc
```

### 2.2 Install Perl 5.42.0

```bash
perlbrew install perl-5.42.0
# Takes 10-20 minutes on t3.small
```

### 2.3 Install cpanm

```bash
perlbrew install-cpanm
```

### 2.4 Verify

```bash
perlbrew exec --with perl-5.42.0 perl -v
# Should show: This is perl 5, version 42, subversion 0
```

---

## Phase 3: Clone and bootstrap 321.do

Still as user `s3`.

### 3.1 Clone the repo

```bash
cd /home/s3
git clone git@github.com:nicholasgasior/web.321.do.git
# Or whatever the actual remote is:
git clone <REPO_URL> web.321.do
cd web.321.do
```

### 3.2 Install Perl deps

```bash
perlbrew exec --with perl-5.42.0 cpanm -L local --notest --installdeps .
```

### 3.3 Install Ubic

```bash
perlbrew exec --with perl-5.42.0 cpanm Ubic Ubic::Service::SimpleDaemon
```

### 3.4 Bootstrap ubic (first-time only)

```bash
perlbrew exec --with perl-5.42.0 ubic-admin setup --batch-mode --local
```

This creates `~/.ubic.cfg` and `~/ubic/` directories.

### 3.5 Generate ubic service files + symlinks

```bash
perlbrew exec --with perl-5.42.0 perl -Ilib bin/321.pl generate
```

### 3.6 Start 321.web

```bash
ubic start 321.web
ubic status 321.web
# Should show: 321.web    running (pid XXXX)
```

### 3.7 Verify the app responds

```bash
curl -s http://127.0.0.1:9321/health
# Should return JSON with status: ok
```

---

## Phase 4: Nginx + SSL

### 4.1 Generate dev SSL certs via mkcert

```bash
mkdir -p ~/.local/share/mkcert
mkcert -cert-file ~/.local/share/mkcert/321.do.dev.pem \
       -key-file  ~/.local/share/mkcert/321.do.dev-key.pem \
       321.do.dev
```

### 4.2 Generate nginx config via 321

```bash
# Set target to dev
perlbrew exec --with perl-5.42.0 perl -Ilib bin/321.pl nginx-setup 321.web
```

Or if the nginx setup command isn't wired for CLI yet, use the API:

```bash
curl -s -u 321:kaizen -X POST http://127.0.0.1:9321/service/321.web/nginx/setup
```

### 4.3 Manual nginx fallback

If the above doesn't work, write the config manually:

```bash
sudo tee /etc/nginx/sites-available/321.do.dev <<'NGINX'
server {
    listen 80;
    listen [::]:80;
    server_name 321.do.dev;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name 321.do.dev;

    ssl_certificate     /home/s3/.local/share/mkcert/321.do.dev.pem;
    ssl_certificate_key /home/s3/.local/share/mkcert/321.do.dev-key.pem;

    ssl_protocols TLSv1.2;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    access_log /var/log/nginx/321.do.dev.access.log;
    error_log  /var/log/nginx/321.do.dev.error.log;

    location / {
        proxy_pass http://127.0.0.1:9321;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 300;
    }
}
NGINX

sudo ln -sf /etc/nginx/sites-available/321.do.dev /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
```

### 4.4 Update /etc/hosts

```bash
sudo perlbrew exec --with perl-5.42.0 perl -Ilib bin/321.pl hosts
# Or manually:
sudo tee -a /etc/hosts <<EOF
# BEGIN 321.do managed
127.0.0.1  321.do.dev
# END 321.do managed
EOF
```

### 4.5 Verify HTTPS

```bash
curl -sk https://321.do.dev/health
# Should return JSON health check
```

---

## Phase 5: Install other services

For each service managed by 321:

```bash
cd /home/s3/web.321.do
perlbrew exec --with perl-5.42.0 perl -Ilib bin/321.pl install <service>
# e.g.: 321 install love.web
```

This clones the repo, installs deps, sets up ubic + nginx + SSL for each service.

---

## Phase 6: DNS

Point `321.do.dev` (and other dev hostnames) at the EC2 instance's public IP, OR use `/etc/hosts` on your local machine for access:

```bash
# On your laptop:
echo "EC2_PUBLIC_IP  321.do.dev" | sudo tee -a /etc/hosts
```

---

## Verification checklist

```
[ ] s3 user exists with sudo
[ ] perlbrew installed, perl-5.42.0 available
[ ] cpanm installed
[ ] git clone of web.321.do in /home/s3/web.321.do
[ ] cpanm -L local deps installed (local/ dir populated)
[ ] Ubic bootstrapped (~/.ubic.cfg exists)
[ ] ubic service files generated (~/ubic/service/321/web exists)
[ ] 321.web running (ubic status 321.web → running)
[ ] curl http://127.0.0.1:9321/health returns OK
[ ] nginx installed and running
[ ] mkcert installed, local CA trusted
[ ] SSL cert generated for 321.do.dev
[ ] nginx config written and enabled
[ ] nginx -t passes
[ ] curl -sk https://321.do.dev/health returns OK
[ ] SOPS + age key in place (sops decrypt services/321.web.yml works)
[ ] /etc/hosts has 321.do.dev → 127.0.0.1
```

---

## Troubleshooting

**perlbrew compile fails on t3.micro:** Not enough RAM. Use t3.small (2 GB) or add swap:
```bash
sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile
sudo mkswap /swapfile && sudo swapon /swapfile
```

**ubic status shows "not running":** Check logs:
```bash
cat /tmp/321.do.stderr.log
cat /tmp/321.do.ubic.log
```

**nginx 502 Bad Gateway:** App not running on port 9321. Check `ubic status 321.web` and restart if needed.

**SOPS decrypt fails:** Age key not in `~/.config/sops/age/keys.txt` or wrong key for the encrypted files.

**mkcert certs not trusted:** Run `mkcert -install` as the s3 user. If accessing from a remote browser, the mkcert CA is only trusted locally — for remote access, use certbot with a real domain instead.
