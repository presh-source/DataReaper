#!/bin/bash
# =============================================================================
# DataReaper Instance Initialization Script
# Runs once on first boot via cloud-init
# =============================================================================
set -euo pipefail
exec > >(tee /var/log/datareaper-init.log) 2>&1

echo "=========================================="
echo "DataReaper Instance Initialization"
echo "Started: $(date)"
echo "=========================================="

# -----------------------------------------------------------------------------
# 1. Format and mount the block volume
# -----------------------------------------------------------------------------
echo "[1/5] Setting up block storage..."

# Wait for the block volume to appear
RETRIES=30
while [ ! -e /dev/sdb ] && [ $RETRIES -gt 0 ]; do
  echo "Waiting for block volume to appear..."
  sleep 5
  RETRIES=$((RETRIES - 1))
done

if [ -e /dev/sdb ]; then
  # Only format if not already formatted
  if ! blkid /dev/sdb; then
    echo "Formatting /dev/sdb as ext4..."
    mkfs.ext4 /dev/sdb
  fi

  mkdir -p /mnt/data
  mount /dev/sdb /mnt/data

  # Add to fstab for persistence across reboots
  if ! grep -q '/dev/sdb' /etc/fstab; then
    echo '/dev/sdb /mnt/data ext4 defaults,_netdev 0 2' >> /etc/fstab
  fi
  echo "Block volume mounted at /mnt/data"
else
  echo "WARNING: Block volume /dev/sdb not found after timeout"
fi

# -----------------------------------------------------------------------------
# 2. Update the OS
# -----------------------------------------------------------------------------
echo "[2/5] Updating OS packages..."
apt-get update -y
apt-get upgrade -y
apt-get install -y ca-certificates curl gnupg lsb-release git

# -----------------------------------------------------------------------------
# 3. Install Docker
# -----------------------------------------------------------------------------
echo "[3/5] Installing Docker..."

# Add Docker's official GPG key
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

# Add Docker repository
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Enable and start Docker
systemctl enable docker
systemctl start docker

# Add ubuntu user to docker group (so they don't need sudo)
usermod -aG docker ubuntu

# Create symlink so 'docker-compose' works (setup.sh uses docker-compose)
ln -sf /usr/libexec/docker/cli-plugins/docker-compose /usr/local/bin/docker-compose

echo "Docker installed: $(docker --version)"

# -----------------------------------------------------------------------------
# 4. Clone the project to the block volume
# -----------------------------------------------------------------------------
echo "[4/5] Setting up project directory..."

PROJECT_DIR="/mnt/data/DataReaper"
mkdir -p "$PROJECT_DIR"
chown -R ubuntu:ubuntu /mnt/data

echo "Project directory ready at $PROJECT_DIR"
echo "Clone your repo here: git clone <your-repo-url> $PROJECT_DIR"

# -----------------------------------------------------------------------------
# 5. Summary
# -----------------------------------------------------------------------------
echo ""
echo "=========================================="
echo "DataReaper Instance Initialization Complete!"
echo "Finished: $(date)"
echo "=========================================="
echo ""
echo "Next steps:"
echo "  1. SSH in:  ssh -i <key> ubuntu@<public-ip>"
echo "  2. Clone:   git clone <repo-url> $PROJECT_DIR"
echo "  3. cd $PROJECT_DIR/docker"
echo "  4. cp .env.example .env  (edit with your secrets)"
echo "  5. ./setup.sh"
echo ""
echo "Logs saved to: /var/log/datareaper-init.log"
