#!/usr/bin/env bash
#
# deploy-openconstructionerp.sh
# Deploy OpenConstructionERP on Ubuntu using Docker Compose.
# This script lives inside the repo itself — run it from a clone/checkout
# of your fork (namtrung205/OpenConstructionERP), no separate git clone step.
#
# Usage:
#   ./deploy-openconstructionerp.sh                          # deploy on localhost:8080
#   ./deploy-openconstructionerp.sh -d example.com            # + nginx reverse proxy + TLS (certbot)
#   ./deploy-openconstructionerp.sh -p 9090                   # custom host port
#
# Re-running the script is safe: it pulls the latest commit (if this is a
# git checkout), keeps the existing .env, and re-runs docker compose up -d.

set -euo pipefail

# ----------------------------- Config ---------------------------------
HOST_PORT="8080"
DOMAIN=""
DISABLE_DEMO="1"     # 1 = disable demo accounts (recommended for internet-exposed deploys)

# ----------------------------- Args -------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--domain) DOMAIN="$2"; shift 2 ;;
    -p|--port)   HOST_PORT="$2"; shift 2 ;;
    --keep-demo) DISABLE_DEMO="0"; shift ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^#//'
      exit 0 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

log() { echo -e "\n\033[1;32m==>\033[0m $*"; }

# ----------------------------- Docker ------------------------------------
if ! command -v docker >/dev/null 2>&1; then
  log "Installing Docker..."
  curl -fsSL https://get.docker.com | sudo sh
  sudo usermod -aG docker "$USER"
fi

DOCKER="docker"
if ! docker info >/dev/null 2>&1; then
  DOCKER="sudo docker"
fi

log "Docker: $($DOCKER --version)"
$DOCKER compose version >/dev/null 2>&1 || { echo "docker compose plugin not found"; exit 1; }

sudo systemctl enable --now docker >/dev/null 2>&1 || true

# ----------------------------- Repo dir -----------------------------------
# Assume this script sits at the root of the repo checkout. cd there
# regardless of where the script was invoked from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [[ -d .git ]] && command -v git >/dev/null 2>&1; then
  log "Existing git checkout detected, pulling latest changes..."
  git pull || log "git pull failed — continuing with the code already on disk."
fi

# ----------------------------- .env ---------------------------------------
if [[ ! -f .env ]]; then
  log "Generating .env with random secrets..."
  {
    echo "POSTGRES_PASSWORD=$(openssl rand -base64 24)"
    echo "JWT_SECRET=$(openssl rand -hex 32)"
    [[ "$DISABLE_DEMO" == "1" ]] && echo "DISABLE_DEMO_ACCOUNTS=1"
  } > .env
  chmod 600 .env
  log ".env created (kept out of git, contains secrets)."
else
  log ".env already exists, leaving it untouched."
fi

# ----------------------------- Compose up ----------------------------------
COMPOSE_FILE="docker-compose.yml"
if [[ -f docker-compose.prod.yml ]]; then
  COMPOSE_FILE="docker-compose.prod.yml"
fi
log "Using compose file: $COMPOSE_FILE"

log "Building and starting containers (this can take a few minutes on first run)..."
$DOCKER compose -f "$COMPOSE_FILE" up -d --build

log "Waiting for the app to respond on port $HOST_PORT..."
for i in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:${HOST_PORT}" >/dev/null 2>&1; then
    break
  fi
  sleep 5
done

$DOCKER compose -f "$COMPOSE_FILE" ps

# ----------------------------- Firewall -------------------------------------
if command -v ufw >/dev/null 2>&1 && sudo ufw status | grep -q "Status: active"; then
  if [[ -n "$DOMAIN" ]]; then
    log "Opening 80/443 (reverse proxy mode)..."
    sudo ufw allow 80/tcp
    sudo ufw allow 443/tcp
  else
    log "Opening port $HOST_PORT..."
    sudo ufw allow "${HOST_PORT}/tcp"
  fi
fi

# ----------------------------- Reverse proxy + TLS ---------------------------
if [[ -n "$DOMAIN" ]]; then
  log "Setting up Nginx reverse proxy + TLS for $DOMAIN..."
  sudo apt install -y nginx certbot python3-certbot-nginx

  sudo tee "/etc/nginx/sites-available/openconstructionerp" >/dev/null <<NGINX
server {
    listen 80;
    server_name ${DOMAIN};
    location / {
        proxy_pass http://127.0.0.1:${HOST_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
NGINX

  sudo ln -sf "/etc/nginx/sites-available/openconstructionerp" "/etc/nginx/sites-enabled/openconstructionerp"
  sudo nginx -t && sudo systemctl reload nginx
  sudo certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "admin@${DOMAIN}" || \
    log "certbot failed or needs interactive input — run 'sudo certbot --nginx -d $DOMAIN' manually."

  log "Done. App available at: https://${DOMAIN}"
else
  server_ip="$(curl -fsS ifconfig.me 2>/dev/null || echo YOUR_SERVER_IP)"
  log "Done. App available at: http://${server_ip}:${HOST_PORT}"
fi

echo
echo "Useful commands (from $SCRIPT_DIR):"
echo "  $DOCKER compose -f $COMPOSE_FILE logs -f app"
echo "  $DOCKER compose -f $COMPOSE_FILE restart"
echo "  git pull && $DOCKER compose -f $COMPOSE_FILE up -d --build   # update (or just re-run this script)"