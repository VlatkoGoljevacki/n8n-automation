# Hetzner Cloud Deployment Checklist

Step-by-step guide for deploying medika-automation (n8n) on Hetzner Cloud.

n8n is NOT publicly exposed — access is via SSH tunnel only.

---

## 1. Hetzner Cloud Setup

- [ ] Create account at [Hetzner Cloud Console](https://console.hetzner.cloud/)
- [ ] Add payment method
- [ ] Create project (e.g. `medika-automation`)

## 2. SSH Key

- [ ] Generate key (if you don't have one):
  ```bash
  ssh-keygen -t ed25519 -C "your-email@example.com"
  cat ~/.ssh/id_ed25519.pub
  ```
- [ ] Add public key to Hetzner: **Security** > **SSH Keys** > **Add SSH Key**

## 3. Create Server

- [ ] **Servers** > **Add Server** with these settings:

| Setting | Value |
|---------|-------|
| Location | Nuremberg (nbg1) or Helsinki (hel1) |
| Image | Ubuntu 22.04 |
| Type | Shared vCPU — **CX21** (2 vCPU, 4GB RAM, ~€5.83/mo) |
| SSH Keys | Select your key |
| Firewall | Create new (see below) |
| Name | `medika-automation` |

- [ ] Firewall rules:
  - SSH (Port 22) — from your IP or `0.0.0.0/0`
  - **No 80/443 needed** — n8n is not publicly exposed

- [ ] Note the server IPv4 address

## 4. Server Initial Configuration

```bash
# Connect as root
ssh root@YOUR_SERVER_IP
```

### Create deploy user

```bash
adduser deploy
usermod -aG sudo deploy

# Copy SSH keys
mkdir -p /home/deploy/.ssh
cp /root/.ssh/authorized_keys /home/deploy/.ssh/
chown -R deploy:deploy /home/deploy/.ssh
chmod 700 /home/deploy/.ssh
chmod 600 /home/deploy/.ssh/authorized_keys
```

- [ ] Test login in a **new terminal**: `ssh deploy@YOUR_SERVER_IP`

### Harden SSH

```bash
# As root, edit /etc/ssh/sshd_config:
nano /etc/ssh/sshd_config
```

Set:
```
PermitRootLogin no
PasswordAuthentication no
```

```bash
systemctl restart ssh
```

### Update system & install Docker

```bash
# As deploy user from now on
sudo apt update && sudo apt upgrade -y

# Install dependencies
sudo apt install -y apt-transport-https ca-certificates curl software-properties-common git htop ncdu

# Install Docker
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh
sudo usermod -aG docker deploy

# Install Docker Compose plugin
sudo apt install -y docker-compose-plugin

# Logout and login again for docker group
exit
```

```bash
ssh deploy@YOUR_SERVER_IP
docker --version
docker compose version
```

### Configure firewall (UFW)

```bash
sudo ufw allow OpenSSH
sudo ufw enable
sudo ufw status
```

Note: No HTTP/HTTPS rules needed — n8n is accessed via SSH tunnel only.

### Enable automatic security updates

```bash
sudo apt install -y unattended-upgrades
sudo dpkg-reconfigure -plow unattended-upgrades
```

## 5. Deploy Application

No git repo on the server. Only two files are needed: `docker-compose.yml` and `.env`.

### From your local machine

```bash
cd /path/to/medika-automation

# Prepare .env with production secrets
cp .env.example /tmp/medika-prod.env
nano /tmp/medika-prod.env
```

- [ ] Fill in all secrets in the `.env`:
  - `N8N_RUNNERS_AUTH_TOKEN` — generate: `openssl rand -base64 32`
  - `N8N_API_KEY` — generate: `openssl rand -base64 32`
  - Medika ERP credentials
  - Microsoft Graph API credentials
  - `PLACES_API` key

```bash
# Copy server compose + env to the server
ssh deploy@YOUR_SERVER_IP "mkdir -p /home/deploy/medika-automation"
scp docker-compose.server.yml deploy@YOUR_SERVER_IP:/home/deploy/medika-automation/docker-compose.yml
scp /tmp/medika-prod.env deploy@YOUR_SERVER_IP:/home/deploy/medika-automation/.env
rm /tmp/medika-prod.env
```

### On the server

```bash
cd /home/deploy/medika-automation

# Start services
docker compose up -d

# Verify
docker compose ps
docker compose logs -f n8n
```

## 6. Access n8n (SSH Tunnel)

n8n is bound to `127.0.0.1` — not reachable from the internet. Use an SSH tunnel:

```bash
# From your local machine
ssh -L 5678:localhost:5678 deploy@YOUR_SERVER_IP

# Then open in browser
# http://localhost:5678
```

Tip: Add to `~/.ssh/config` for convenience:
```
Host medika
  HostName YOUR_SERVER_IP
  User deploy
  LocalForward 5678 localhost:5678
```

Then just: `ssh medika` and open http://localhost:5678

## 7. Deploy Workflows

```bash
# From your local machine (with tunnel active)
cd /path/to/medika-automation

# Deploy test workflows
./scripts/deploy-workflows.sh medika-preorders

# Deploy prod workflows
./scripts/deploy-workflows.sh medika-preorders promote --deploy
```

## 8. Automated Backups

Two layers: Hetzner server snapshots + local daily volume backups.

### Enable Hetzner automated backups (~€1.17/mo)

- [ ] Hetzner Console > your server > **Backups** tab > **Enable**
- Weekly full-server snapshots, 7-day rolling retention
- Covers everything: OS, Docker, volumes, config

### Create local daily backup script

```bash
mkdir -p /home/deploy/backups
nano /home/deploy/backup-n8n.sh
```

```bash
#!/bin/bash
BACKUP_DIR="/home/deploy/backups"
DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="$BACKUP_DIR/n8n_backup_$DATE.tar.gz"
KEEP_DAYS=30

echo "Creating n8n backup: $BACKUP_FILE"

# Backup the named volume
docker run --rm \
  -v n8n_data:/data \
  -v "$BACKUP_DIR":/backup \
  alpine tar czf "/backup/n8n_backup_$DATE.tar.gz" -C /data .

# Delete old backups
find "$BACKUP_DIR" -name "n8n_backup_*.tar.gz" -mtime +$KEEP_DAYS -delete

echo "Backup done: $(du -h "$BACKUP_FILE" | cut -f1)"
```

```bash
chmod +x /home/deploy/backup-n8n.sh

# Test it
/home/deploy/backup-n8n.sh
```

### Schedule daily at 2 AM

```bash
crontab -e
```

```cron
0 2 * * * /home/deploy/backup-n8n.sh >> /home/deploy/backups/backup.log 2>&1
```

### Restore from backup

```bash
cd /home/deploy/medika-automation
docker compose down

# Restore volume from backup
docker run --rm \
  -v n8n_data:/data \
  -v /home/deploy/backups:/backup \
  alpine sh -c "rm -rf /data/* && tar xzf /backup/n8n_backup_YYYYMMDD_HHMMSS.tar.gz -C /data"

docker compose up -d
```

## 9. Disk Space Monitoring

A cron script checks disk usage every 6 hours and calls an n8n webhook when it exceeds 80%.

### Prerequisites

- [ ] Create a workflow in n8n: **Webhook trigger** (path: `disk-alert`) → **Send Email** node
- [ ] Note the webhook production URL (will be `http://localhost:5678/webhook/disk-alert`)

### Create monitoring script

```bash
nano /home/deploy/check-disk.sh
```

```bash
#!/bin/bash
THRESHOLD=80
WEBHOOK_URL="http://localhost:5678/webhook/disk-alert"
LOG_FILE="/home/deploy/backups/disk-monitor.log"

USAGE=$(df / --output=pcent | tail -1 | tr -dc '0-9')

if [ "$USAGE" -ge "$THRESHOLD" ]; then
  DISK_INFO=$(df -h / --output=size,used,avail,pcent | tail -1)
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$WEBHOOK_URL" \
    -H "Content-Type: application/json" \
    -d "{\"usage\": $USAGE, \"detail\": \"$DISK_INFO\", \"hostname\": \"$(hostname)\"}")

  if [ "$HTTP_CODE" != "200" ]; then
    echo "$(date): Disk at ${USAGE}% — webhook failed (HTTP $HTTP_CODE)" >> "$LOG_FILE"
  fi
fi
```

```bash
chmod +x /home/deploy/check-disk.sh
```

### Schedule every 2 weeks

```bash
crontab -e
```

```cron
0 9 1,15 * * /home/deploy/check-disk.sh
```

## 10. Maintenance

```bash
# View logs
docker compose logs -f n8n

# Restart
docker compose restart

# Update n8n (pull latest image)
docker compose pull
docker compose up -d

# Update docker-compose.yml on server (from local machine)
scp docker-compose.server.yml deploy@SERVER:/home/deploy/medika-automation/docker-compose.yml
ssh deploy@SERVER "cd medika-automation && docker compose up -d"

# Check disk/memory
df -h
free -h
htop

# Check backup status
ls -lh /home/deploy/backups/ | tail -5
```

---

## Quick Reference

```bash
# SSH with tunnel
ssh -L 5678:localhost:5678 deploy@YOUR_SERVER_IP

# Start/stop
docker compose up -d
docker compose down

# Logs
docker compose logs -f n8n
docker compose logs -f n8n-runner

# Deploy workflows
./scripts/deploy-workflows.sh medika-preorders
./scripts/deploy-workflows.sh medika-preorders --env prod

# Manual backup
/home/deploy/backup-n8n.sh
```

## Cost

| Item | Cost |
|------|------|
| Hetzner CX21 (2 vCPU, 4GB RAM) | ~€5.83/mo |
| Hetzner automated backups (optional) | ~€1.17/mo |
| **Total** | **~€6-7/mo** |
