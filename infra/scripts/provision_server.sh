#!/bin/bash
set -e

# =============================================================================
# Deployment Script: provisions the server with local code and runs setup.sh
# Usage: ./provision_server.sh <public_ip> <path_to_private_key>
# =============================================================================

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <public_ip> <path_to_private_key>"
    exit 1
fi

PUBLIC_IP=$1
PRIVATE_KEY=$2
PROJECT_DIR_ON_SERVER="/mnt/data/DataReaper"
LOCAL_PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

echo "=========================================="
echo "Deploying to server: $PUBLIC_IP"
echo "=========================================="

# 1. Wait for Cloud-Init to finish (Docker installation, formatting, mounting)
echo "[1/3] Waiting for cloud-init to finish (this may take a few minutes)..."
ssh -o StrictHostKeyChecking=no -i "$PRIVATE_KEY" ubuntu@"$PUBLIC_IP" << 'EOF'
  while [ ! -f /var/lib/cloud/instance/boot-finished ]; do
    echo "Waiting for cloud-init..."
    sleep 5
  done
  echo "Cloud-init finished!"
  
  # Ensure the project directory is owned by ubuntu user
  sudo mkdir -p /mnt/data/DataReaper
  sudo chown -R ubuntu:ubuntu /mnt/data
EOF

# 2. Sync local files to the server
echo "[2/3] Uploading project files to the server..."
# We use rsync to quickly copy everything over, excluding .git, terraform state, etc.
rsync -avz -e "ssh -o StrictHostKeyChecking=no -i $PRIVATE_KEY" \
    --exclude '.git' \
    --exclude 'infra/tf/.terraform' \
    --exclude 'infra/tf/terraform.tfstate*' \
    --exclude '__pycache__' \
    "$LOCAL_PROJECT_ROOT/" ubuntu@"$PUBLIC_IP":"$PROJECT_DIR_ON_SERVER/"

# 3. Run setup.sh on the remote server
echo "[3/3] Running docker setup.sh on the server..."
ssh -o StrictHostKeyChecking=no -i "$PRIVATE_KEY" ubuntu@"$PUBLIC_IP" << EOF
  cd $PROJECT_DIR_ON_SERVER/docker
  
  # Check if .env exists, if not, copy an example or error out
  if [ ! -f .env ]; then
    if [ -f .env.example ]; then
      echo "No .env file found. Copying .env.example..."
      cp .env.example .env
      echo "⚠️ IMPORTANT: Replace placeholder passwords in .env!"
    else
      echo "❌ Error: No .env file exists and no .env.example found."
      exit 1
    fi
  fi
  
  # Make sure setup.sh is executable
  chmod +x setup.sh
  
  # Run setup script mapping the user instructions
  ./setup.sh
EOF

echo "=========================================="
echo "Deployment Complete!"
echo "=========================================="
