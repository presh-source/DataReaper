#!/bin/bash
set -e

# -----------------------------------------------------------------------------
# Command Line Arguments Parsing
# -----------------------------------------------------------------------------
FORCE_RESET=false
ROTATE_LIVE=false
RESTART=false
DOWN=false
DELETE=false
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -f|--force)   FORCE_RESET=true ;;
        --rotate)     ROTATE_LIVE=true ;;
        --restart)    RESTART=true ;;
        --down)       DOWN=true ;;
        --delete)     DELETE=true ;;
        -h|--help)
            echo "Usage: ./manage.sh [OPTION]"
            echo ""
            echo "Options:"
            echo "  (no flag)     Ensure services are up and re-seed configs"
            echo "  -r, --rotate  Live password rotation (no data loss)"
            echo "  -f, --force   Nuclear reset — wipes all data and restarts fresh"
            echo "  --restart     Restart all containers (no data loss)"
            echo "  --down        Stop and remove containers (volumes are kept)"
            echo "  --delete      Stop containers AND permanently delete all volumes"
            echo "  -h, --help    Show this help message"
            exit 0 ;;
        *) echo "Unknown parameter: $1. Run ./manage.sh --help for usage."; exit 1 ;;
    esac
    shift
done

# -----------------------------------------------------------------------------
# Utility Functions
# -----------------------------------------------------------------------------
safe_sed() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "$1" "$2"
  else
    sed -i "$1" "$2"
  fi
}

prepare_license() {
  source .env
  if [ -n "$MINIO_LICENSE" ]; then
    echo "Writing MinIO license to .minio.license..."
    echo "$MINIO_LICENSE" > .minio.license
  fi
}

# -----------------------------------------------------------------------------
# LIVE PASSWORD ROTATION (No Data Loss)
# -----------------------------------------------------------------------------
rotate_passwords_live() {
  echo "--- STARTING LIVE PASSWORD ROTATION ---"
  source .env
  
  # 1. Capture OLD passwords
  OLD_PG_PASS=$POSTGRES_PASSWORD
  OLD_MONGO_PASS=$MONGO_PASSWORD
  
  # 2. Generate NEW passwords
  NEW_PG_PASS=$(openssl rand -hex 12)
  NEW_MONGO_PASS=$(openssl rand -hex 12)
  NEW_MINIO_PASS=$(openssl rand -hex 12)
  NEW_AIRFLOW_PASS=$(openssl rand -hex 12)

  echo "Updating live databases with new credentials..."

  # 3. Update PostgreSQL Live
  docker-compose exec -T postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "ALTER USER $POSTGRES_USER WITH PASSWORD '$NEW_PG_PASS';"
  
  # 4. Update MongoDB Live
  docker-compose exec -T mongodb mongosh -u "$MONGO_USER" -p "$OLD_MONGO_PASS" --authenticationDatabase admin --eval "
    db.getSiblingDB('admin').changeUserPassword('$MONGO_USER', '$NEW_MONGO_PASS')
  "

  # 5. Update MinIO password live via mc CLI
  echo "Rotating MinIO root password..."
  docker-compose exec -T aistor sh -c "
    mc alias set local http://localhost:9000 \"$MINIO_ROOT_USER\" \"$MINIO_ROOT_PASSWORD\" &&
    mc admin user password local \"$MINIO_ROOT_USER\" \"$NEW_MINIO_PASS\"
  "

  # 6. Update .env File
  echo "Syncing .env file..."
  safe_sed "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$NEW_PG_PASS|" .env
  safe_sed "s|^MONGO_PASSWORD=.*|MONGO_PASSWORD=$NEW_MONGO_PASS|" .env
  safe_sed "s|^MINIO_ROOT_PASSWORD=.*|MINIO_ROOT_PASSWORD=$NEW_MINIO_PASS|" .env
  safe_sed "s|^AIRFLOW__DATABASE__SQL_ALCHEMY_CONN=.*|AIRFLOW__DATABASE__SQL_ALCHEMY_CONN=postgresql+psycopg2://airflow:$NEW_PG_PASS@postgres/airflow|" .env
  safe_sed "s|^_AIRFLOW_WWW_USER_PASSWORD=.*|_AIRFLOW_WWW_USER_PASSWORD=$NEW_AIRFLOW_PASS|" .env

  # 7. Update MongoDB Secrets Collection
  docker-compose exec -T mongodb mongosh -u "$MONGO_USER" -p "$NEW_MONGO_PASS" --authenticationDatabase admin --eval "
    const db = db.getSiblingDB('$PROJECT_NAME');
    db.secrets.updateOne({ env: 'global' }, {
      \$set: {
        postgres_pass: '$NEW_PG_PASS',
        mongo_pass: '$NEW_MONGO_PASS',
        minio_pass: '$NEW_MINIO_PASS',
        airflow_pass: '$NEW_AIRFLOW_PASS'
      }
    }, { upsert: true });
  "

  # 8. Update Airflow web UI user password live (without restart)
  echo "Updating Airflow web UI password..."
  docker-compose exec -T airflow-apiserver airflow users set-password \
    --username "$_AIRFLOW_WWW_USER_USERNAME" \
    --password "$NEW_AIRFLOW_PASS"

  # 9. Restart services to apply env changes (NO -v FLAG!)
  echo "Restarting containers to apply new environment variables..."
  docker-compose up -d --force-recreate
  
  echo ""
  echo "Rotation Complete! All data preserved."
  echo "  Airflow UI login → user: $_AIRFLOW_WWW_USER_USERNAME  password: $NEW_AIRFLOW_PASS"
  echo "  (Also saved to .env as _AIRFLOW_WWW_USER_PASSWORD)"
}

# -----------------------------------------------------------------------------
# NUCLEAR RESET (Data Loss)
# -----------------------------------------------------------------------------
generate_and_apply_passwords_nuclear() {
  echo "--- STARTING NUCLEAR RESET (DATA WILL BE WIPED) ---"
  NEW_PG_PASS=$(openssl rand -hex 12)
  NEW_MONGO_PASS=$(openssl rand -hex 12)
  NEW_MINIO_PASS=$(openssl rand -hex 12)
  NEW_AIRFLOW_PASS=$(openssl rand -hex 12)

  safe_sed "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$NEW_PG_PASS|" .env
  safe_sed "s|^MONGO_PASSWORD=.*|MONGO_PASSWORD=$NEW_MONGO_PASS|" .env
  safe_sed "s|^MINIO_ROOT_PASSWORD=.*|MINIO_ROOT_PASSWORD=$NEW_MINIO_PASS|" .env
  safe_sed "s|^_AIRFLOW_WWW_USER_PASSWORD=.*|_AIRFLOW_WWW_USER_PASSWORD=$NEW_AIRFLOW_PASS|" .env
  safe_sed "s|^AIRFLOW__DATABASE__SQL_ALCHEMY_CONN=.*|AIRFLOW__DATABASE__SQL_ALCHEMY_CONN=postgresql+psycopg2://airflow:$NEW_PG_PASS@postgres/airflow|" .env

  source .env
  docker-compose down -v
  docker-compose up -d

  printf "Waiting for services..."
  until docker-compose exec -T mongodb mongosh -u "$MONGO_USER" -p "$NEW_MONGO_PASS" --authenticationDatabase admin --eval "db.runCommand({ ping: 1 })" > /dev/null 2>&1; do
    printf "." ; sleep 2
  done
  echo " Ready!"

  # Seed airflow_pass into MongoDB secrets after fresh start
  docker-compose exec -T mongodb mongosh -u "$MONGO_USER" -p "$NEW_MONGO_PASS" --authenticationDatabase admin --eval "
    const db = db.getSiblingDB('$PROJECT_NAME');
    db.secrets.updateOne({ env: 'global' }, {
      \$set: { airflow_pass: '$NEW_AIRFLOW_PASS' }
    }, { upsert: true });
  "

  echo ""
  echo "  Airflow UI login → user: $_AIRFLOW_WWW_USER_USERNAME  password: $NEW_AIRFLOW_PASS"
  echo "  (Also saved to .env as _AIRFLOW_WWW_USER_PASSWORD)"
}

# -----------------------------------------------------------------------------
# RESTART — Recreate all containers, keep volumes intact
# -----------------------------------------------------------------------------
restart_services() {
  echo "--- RESTARTING ALL CONTAINERS ---"
  docker-compose up -d --force-recreate
  echo "Restart Complete!"
}

# -----------------------------------------------------------------------------
# DOWN — Stop and remove containers, keep volumes
# -----------------------------------------------------------------------------
down_services() {
  echo "--- STOPPING CONTAINERS (volumes preserved) ---"
  docker-compose down
  echo "All containers stopped. Data volumes are intact."
}

# -----------------------------------------------------------------------------
# DELETE — Stop containers AND permanently wipe all volumes
# -----------------------------------------------------------------------------
delete_all() {
  echo "--- ⚠️  DELETING ALL CONTAINERS AND VOLUMES ⚠️  ---"
  read -r -p "Are you sure? This will permanently delete ALL data. [y/N]: " confirm
  if [[ "$confirm" =~ ^[Yy]$ ]]; then
    docker-compose down -v
    echo "All containers and volumes permanently deleted."
  else
    echo "Aborted."
    exit 0
  fi
}

# -----------------------------------------------------------------------------
# Seeding and Setup
# -----------------------------------------------------------------------------
setup_minio_buckets() {
  source .env
  docker-compose exec -T aistor sh -c "mc alias set $PROJECT_NAME http://localhost:9000 \"\$MINIO_ROOT_USER\" \"\$MINIO_ROOT_PASSWORD\" && mc mb $PROJECT_NAME/$GITHUB_BUCKET_NAME --ignore-existing"
}

seed_mongo_configs() {
  source .env
  docker-compose exec -T mongodb mongosh -u "$MONGO_USER" -p "$MONGO_PASSWORD" --authenticationDatabase admin --eval "
    const db = db.getSiblingDB('$PROJECT_NAME');
    db.secrets.updateOne({ env: 'global' }, { \$set: { project_name: '$PROJECT_NAME', minio_user: '$MINIO_ROOT_USER', minio_pass: '$MINIO_ROOT_PASSWORD' } }, { upsert: true });
    db.secrets.updateOne({ env: 'github' }, { \$set: { github_token: '$GITHUB_TOKEN', github_bucket: '$GITHUB_BUCKET_NAME' } }, { upsert: true });
    
    // Seed Crawler Configs
    db.crawler_config.createIndex({ state_key: 1 }, { unique: true });
    const configs = [
      { key: 'U1RBVEUjZ2l0aHViI3JlcG9zaXRvcnk=', entity: 'repository', prefix: 'repositories', endpoint: 'https://api.github.com/repositories' },
      { key: 'U1RBVEUjZ2l0aHViI3VzZXI=', entity: 'user', prefix: 'users', endpoint: 'https://api.github.com/users' }
    ];
    configs.forEach(c => {
      db.crawler_config.updateOne({ state_key: c.key }, {
        \$set: { organisation: 'github', entity: c.entity, minio_prefix: c.prefix, endpoint: c.endpoint, requests_per_execution: 1200, sleep_interval: 0.1 },
        \$setOnInsert: { last_processed_id: 0, total_processed: 0, updated_at: new Date().toISOString() }
      }, { upsert: true });
    });
  "
}

# =============================================================================
# Execution Block
# =============================================================================
if [ ! -f .env ]; then echo "Error: .env not found"; exit 1; fi
prepare_license
source .env

if [ "$DELETE" = true ]; then
    delete_all
    exit 0
elif [ "$DOWN" = true ]; then
    down_services
    exit 0
elif [ "$RESTART" = true ]; then
    restart_services
    exit 0
elif [ "$FORCE_RESET" = true ]; then
    generate_and_apply_passwords_nuclear
elif [ "$ROTATE_LIVE" = true ]; then
    rotate_passwords_live
else
    echo "Ensuring services are up..."
    docker-compose up -d
fi

# Run seeding (Idempotent — safe after any startup)
setup_minio_buckets
seed_mongo_configs

echo "Setup/Update Complete!"
