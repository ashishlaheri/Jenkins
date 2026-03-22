#!/bin/bash
# =============================================================================
# Jenkins Auto-Installer for Ubuntu 22.04 on AWS EC2
# Stack: Java 17 + Jenkins LTS + Nginx + Self-Signed SSL
# Auto-detects EC2 Public IP from AWS Instance Metadata Service
# =============================================================================

set -e  # Stop immediately on any error

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ── Helpers ───────────────────────────────────────────────────────────────────
step()    { echo -e "\n${CYAN}${BOLD}▶ $1${NC}"; }
success() { echo -e "${GREEN}✔ $1${NC}"; }
warn()    { echo -e "${YELLOW}⚠ $1${NC}"; }
error()   { echo -e "${RED}✘ ERROR: $1${NC}"; exit 1; }

# ── Root Check ────────────────────────────────────────────────────────────────
if [[ "$EUID" -ne 0 ]]; then
  error "Please run this script as root: sudo bash install_jenkins.sh"
fi

# =============================================================================
# STEP 0 — Auto-detect EC2 Public IP via AWS IMDSv2
# =============================================================================
step "Detecting EC2 Public IP..."

# IMDSv2 requires a token first (more secure than IMDSv1)
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" 2>/dev/null || true)

if [[ -n "$TOKEN" ]]; then
  PUBLIC_IP=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
    http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || true)
fi

# Fallback to IMDSv1 if IMDSv2 token failed
if [[ -z "$PUBLIC_IP" ]]; then
  PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || true)
fi

# Final fallback: ask user
if [[ -z "$PUBLIC_IP" ]]; then
  warn "Could not auto-detect EC2 public IP."
  read -rp "Please enter your EC2 Public IP manually: " PUBLIC_IP
fi

# Validate IP format
if [[ ! "$PUBLIC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  error "Invalid IP address detected: '$PUBLIC_IP'. Please re-run and enter it manually."
fi

success "EC2 Public IP detected: $PUBLIC_IP"

# =============================================================================
# STEP 1 — System Update
# =============================================================================
step "Updating system packages..."
apt update -y
apt upgrade -y
success "System updated."

# =============================================================================
# STEP 2 — Install Java 17
# =============================================================================
step "Installing Java 17..."
apt install -y fontconfig openjdk-17-jre

JAVA_VER=$(java -version 2>&1 | head -n1)
success "Java installed: $JAVA_VER"

# =============================================================================
# STEP 3 — Add Jenkins LTS Repository (using exact key ID — proven to work)
# =============================================================================
step "Setting up Jenkins LTS repository..."

# Clean any previous broken attempts
rm -f /usr/share/keyrings/jenkins-keyring.asc
rm -f /usr/share/keyrings/jenkins-keyring.gpg
rm -f /etc/apt/sources.list.d/jenkins.list

# Fetch the exact Jenkins signing key by its ID from Ubuntu keyserver
# Key ID 7198F4B714ABFC68 is what pkg.jenkins.io/debian-stable uses
gpg --keyserver hkp://keyserver.ubuntu.com:80 \
    --recv-keys 7198F4B714ABFC68 \
    || error "Failed to fetch Jenkins GPG key from keyserver. Check your internet connection."

# Export it in binary format that apt requires
gpg --export 7198F4B714ABFC68 \
    | tee /usr/share/keyrings/jenkins-keyring.gpg > /dev/null

# Verify key file is not empty
KEY_SIZE=$(stat -c%s /usr/share/keyrings/jenkins-keyring.gpg)
if [[ "$KEY_SIZE" -lt 100 ]]; then
  error "Jenkins GPG key file is too small ($KEY_SIZE bytes). Key export may have failed."
fi

success "Jenkins GPG key saved (${KEY_SIZE} bytes)."

# Add Jenkins LTS repo
echo "deb [signed-by=/usr/share/keyrings/jenkins-keyring.gpg] \
https://pkg.jenkins.io/debian-stable binary/" \
  | tee /etc/apt/sources.list.d/jenkins.list > /dev/null

success "Jenkins repository added."

# =============================================================================
# STEP 4 — Install Jenkins LTS
# =============================================================================
step "Installing Jenkins LTS..."
apt update -y
apt install -y jenkins
success "Jenkins installed."

# =============================================================================
# STEP 5 — Start & Enable Jenkins
# =============================================================================
step "Starting Jenkins service..."
systemctl start jenkins
systemctl enable jenkins

# Wait a moment and verify
sleep 5
if systemctl is-active --quiet jenkins; then
  success "Jenkins is running."
else
  error "Jenkins failed to start. Run: sudo journalctl -u jenkins -n 50 --no-pager"
fi

# =============================================================================
# STEP 6 — Generate Self-Signed SSL Certificate
# =============================================================================
step "Generating self-signed SSL certificate for IP: $PUBLIC_IP ..."

openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /etc/ssl/private/jenkins-selfsigned.key \
  -out    /etc/ssl/certs/jenkins-selfsigned.crt \
  -subj   "/C=US/ST=State/L=City/O=Jenkins/CN=${PUBLIC_IP}"

chmod 600 /etc/ssl/private/jenkins-selfsigned.key
success "SSL certificate generated."

# =============================================================================
# STEP 7 — Install & Configure Nginx
# =============================================================================
step "Installing Nginx..."
apt install -y nginx
success "Nginx installed."

step "Configuring Nginx as reverse proxy for Jenkins..."

# Remove default site
rm -f /etc/nginx/sites-enabled/default

# Write Jenkins Nginx config
cat > /etc/nginx/sites-available/jenkins <<NGINXCONF
server {
    listen 80;
    server_name ${PUBLIC_IP};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name ${PUBLIC_IP};

    ssl_certificate     /etc/ssl/certs/jenkins-selfsigned.crt;
    ssl_certificate_key /etc/ssl/private/jenkins-selfsigned.key;

    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    location / {
        proxy_pass          http://127.0.0.1:8080;
        proxy_http_version  1.1;

        proxy_set_header    Host              \$host;
        proxy_set_header    X-Real-IP         \$remote_addr;
        proxy_set_header    X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header    X-Forwarded-Proto \$scheme;

        proxy_read_timeout    90s;
        proxy_connect_timeout 90s;
        proxy_send_timeout    90s;

        # Required for Jenkins WebSocket agents
        proxy_set_header    Upgrade    \$http_upgrade;
        proxy_set_header    Connection "upgrade";
    }
}
NGINXCONF

# Enable the site
ln -sf /etc/nginx/sites-available/jenkins /etc/nginx/sites-enabled/jenkins

# Test Nginx config
nginx -t || error "Nginx config test failed. Check /etc/nginx/sites-available/jenkins"

# Restart and enable Nginx
systemctl restart nginx
systemctl enable nginx

if systemctl is-active --quiet nginx; then
  success "Nginx is running."
else
  error "Nginx failed to start. Run: sudo journalctl -u nginx -n 50 --no-pager"
fi

# =============================================================================
# STEP 8 — Wait for Jenkins to fully initialize and print admin password
# =============================================================================
step "Waiting for Jenkins to fully initialize (this may take up to 60 seconds)..."

PASSWORD_FILE="/var/lib/jenkins/secrets/initialAdminPassword"
WAITED=0
MAX_WAIT=90

until [[ -f "$PASSWORD_FILE" ]]; do
  sleep 5
  WAITED=$((WAITED + 5))
  echo -e "  ${YELLOW}Still waiting... (${WAITED}s / ${MAX_WAIT}s)${NC}"
  if [[ "$WAITED" -ge "$MAX_WAIT" ]]; then
    error "Jenkins did not initialize within ${MAX_WAIT}s. Check logs: sudo journalctl -u jenkins -n 50 --no-pager"
  fi
done

ADMIN_PASSWORD=$(cat "$PASSWORD_FILE")

# =============================================================================
# DONE — Print Summary
# =============================================================================
echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║           ✅  JENKINS INSTALLATION COMPLETE!                ║${NC}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Access Jenkins at:${NC}       ${CYAN}https://${PUBLIC_IP}${NC}"
echo -e "  ${BOLD}Initial Admin Password:${NC}  ${YELLOW}${ADMIN_PASSWORD}${NC}"
echo ""
echo -e "  ${BOLD}Next steps:${NC}"
echo -e "  1. Open ${CYAN}https://${PUBLIC_IP}${NC} in your browser"
echo -e "  2. Click ${BOLD}Advanced → Proceed${NC} on the SSL warning (self-signed cert)"
echo -e "  3. Paste the password above and click ${BOLD}Continue${NC}"
echo -e "  4. Click ${BOLD}Install suggested plugins${NC}"
echo -e "  5. Create your admin user"
echo -e "  6. Set Jenkins URL to: ${CYAN}https://${PUBLIC_IP}${NC}"
echo ""
echo -e "  ${BOLD}Useful commands:${NC}"
echo -e "  ${CYAN}sudo systemctl status jenkins${NC}   — Check Jenkins status"
echo -e "  ${CYAN}sudo systemctl status nginx${NC}     — Check Nginx status"
echo -e "  ${CYAN}sudo journalctl -u jenkins -n 50 --no-pager${NC}  — Jenkins logs"
echo ""
