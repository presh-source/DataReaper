# DataReaper 🕷️

A self-hosted data pipeline that continuously crawls the GitHub API to collect public **repository** and **user** data, stores it as compressed Parquet files in object storage, and orchestrates everything with Apache Airflow.

---

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│                      Docker Network                      │
│                                                          │
│  ┌──────────────┐    ┌───────────────┐    ┌───────────┐  │
│  │   Airflow    │───▶│   MongoDB     │    │  AiStor   │  │
│  │  (Scheduler  │    │               │    │  (MinIO)  │  │
│  │   API Server │    │ crawler_config│    │           │  │
│  │   Triggerer) │    │ secrets       │    │ github-   │  │
│  └──────┬───────┘    └───────────────┘    │ data/     │  │
│         │                                 │  parquet  │  │
│         │  DAG: github_crawler_dag        └───────────┘  │
│         │  ↓ reads config from MongoDB                   │
│         │  ↓ hits GitHub API                             │
│         │  ↓ writes Parquet to AiStor                    │
│         │                                                │
│  ┌──────────────┐                                        │
│  │  PostgreSQL  │  (Airflow metadata DB)                 │
│  └──────────────┘                                        │
└──────────────────────────────────────────────────────────┘
```

### Services

| Service | Port | Purpose |
|---|---|---|
| `airflow-apiserver` | `8080` | Airflow Web UI & REST API |
| `airflow-scheduler` | — | Schedules and triggers DAG runs |
| `airflow-dag-processor` | — | Parses and validates DAG files |
| `airflow-triggerer` | — | Handles deferred/async tasks |
| `postgres` | `5432` | Airflow metadata database |
| `mongodb` | `27017` | Crawler config & secrets store |
| `aistor` (MinIO) | `9000` / `9001` | Object storage for Parquet files |

### Data Flow

1. Airflow triggers `github_crawler_dag` on a schedule (`@hourly`)
2. The crawler reads its configuration (endpoint, last processed ID, rate limits) from **MongoDB** (`crawler_config` collection)
3. It reads credentials (GitHub token, MinIO user/pass) from **MongoDB** (`secrets` collection)
4. It paginates the GitHub API (`/repositories` or `/users`) starting from the last processed ID
5. Data is batched, flattened, and saved to **AiStor** as Parquet files partitioned by `year/month/day`
6. The last processed ID and total count are written back to **MongoDB** as a bookmark

---

## Prerequisites

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) installed and running
- A **MinIO AiStor license** (free tier available at [min.io](https://min.io))
- A **GitHub Personal Access Token** with `public_repo` read scope

---

## First-Time Setup

### 1. Clone the repository

```bash
git clone <your-repo-url>
cd DataReaper
```

### 2. Create your `.env` file

Copy the example values and fill in your secrets:

```bash
cp .env.example .env   # if one exists, otherwise edit .env directly
```

Required values in `.env`:

```env
# Project
PROJECT_NAME=DataReaper

# Airflow (leave defaults for local dev)
_AIRFLOW_WWW_USER_USERNAME=airflow
_AIRFLOW_WWW_USER_PASSWORD=airflow
AIRFLOW_UID=50000

# PostgreSQL (will be randomised by setup.sh -f)
POSTGRES_USER=airflow
POSTGRES_PASSWORD=changeme
POSTGRES_DB=airflow

# MongoDB (will be randomised by setup.sh -f)
MONGO_USER=root
MONGO_PASSWORD=changeme

# MinIO AiStor (will be randomised by setup.sh -f)
MINIO_ROOT_USER=minioadmin
MINIO_ROOT_PASSWORD=changeme
MINIO_LICENSE=<paste your license JWT here>

# GitHub
GITHUB_TOKEN=<your GitHub personal access token>
GITHUB_BUCKET_NAME=github-data
```

> ⚠️ `MINIO_LICENSE` is **required**. The setup script will exit if it is missing.

### 3. Run the setup script

```bash
chmod +x setup.sh
./setup.sh --force
```

This will:
- ✅ Write your MinIO license to `.minio.license`
- ✅ Generate secure random passwords for Postgres, MongoDB, MinIO, **and Airflow**
- ✅ Update your `.env` file with the new passwords
- ✅ Spin up all Docker containers from scratch
- ✅ Wait for MongoDB to be ready
- ✅ Create the `github-data` MinIO bucket
- ✅ Seed MongoDB with crawler configs and all credentials

At the end of the run, your **Airflow login credentials** will be printed to the terminal:

```
  Airflow UI login → user: airflow  password: <generated-password>
  (Also saved to .env as _AIRFLOW_WWW_USER_PASSWORD)
```

### 4. Open the Airflow UI

Once all containers are healthy, visit:

```
http://localhost:8080
```

Login with the credentials printed at the end of `setup.sh --force`, or look them up in `.env`:
- **Username:** value of `_AIRFLOW_WWW_USER_USERNAME` (default: `airflow`)
- **Password:** value of `_AIRFLOW_WWW_USER_PASSWORD` (randomised by `setup.sh`)

> ℹ️ Example DAGs are **disabled** by default (`AIRFLOW__CORE__LOAD_EXAMPLES=false`).

### 5. Trigger a DAG run

Find `github_crawler_dag` in the UI and trigger it with a config JSON:

```json
{ "state_key": "U1RBVEUjZ2l0aHViI3JlcG9zaXRvcnk=" }
```

State keys:

| Key | Crawls |
|---|---|
| `U1RBVEUjZ2l0aHViI3JlcG9zaXRvcnk=` | GitHub Repositories |
| `U1RBVEUjZ2l0aHViI3VzZXI=` | GitHub Users |

---

## setup.sh Reference

`setup.sh` is the single script for controlling your entire environment.

```bash
./setup.sh            # Ensure services are up + re-seed configs (safe, idempotent)
./setup.sh --force    # Nuclear reset — wipe all data and restart with new passwords
./setup.sh --rotate   # Live password rotation — rotate credentials without data loss
./setup.sh --restart  # Restart all containers (volumes untouched)
./setup.sh --down     # Stop and remove containers (volumes preserved)
./setup.sh --delete   # ⚠️  Permanently delete all containers AND volumes
./setup.sh --help     # Show all options
```

> 💡 Run `./setup.sh` (no flags) at any time to ensure services are running and configs are up to date. It is fully idempotent.

### What gets rotated

| Flag | Postgres | MongoDB | MinIO | Airflow UI | Volumes |
|---|:---:|:---:|:---:|:---:|:---:|
| `--rotate` | ✅ live | ✅ live | ✅ env | ✅ live | preserved |
| `--force` | ✅ reset | ✅ reset | ✅ reset | ✅ reset | **wiped** |

After either flag, new credentials are printed to the terminal **and** saved to both `.env` and the MongoDB `secrets` collection.

---

## Project Structure

```
DataReaper/
├── dags/
│   └── github/
│       ├── src/
│       │   └── github_crawler.py    # Airflow DAG + crawler logic
│       └── utils/
│           ├── crawler_utils.py     # Config and secret fetching from MongoDB
│           └── sentry_config.py     # Error tracking setup
├── config/                          # Airflow config files
├── logs/                            # Airflow task logs
├── plugins/                         # Airflow plugins
├── deps/                            # Python dependencies
├── docker-compose.yaml              # All service definitions
├── Dockerfile                       # Custom Airflow image
├── setup.sh                        # Environment management script
└── .env                             # Local secrets (never commit this!)
```

---

## MongoDB Collections

| Database | Collection | Purpose |
|---|---|---|
| `DataReaper` | `secrets` | Stores all credentials (env: `global`, env: `github`) |
| `DataReaper` | `crawler_config` | Per-entity crawl state (last ID, total processed, endpoint) |

### `secrets` document (env: `global`)

| Field | Value |
|---|---|
| `postgres_pass` | PostgreSQL password |
| `mongo_pass` | MongoDB password |
| `minio_pass` | MinIO / AiStor password |
| `airflow_pass` | Airflow Web UI password |
| `mongo_user` | MongoDB username |
| `minio_user` | MinIO username |
| `project_name` | Project identifier |

### `secrets` document (env: `github`)

| Field | Value |
|---|---|
| `github_token` | GitHub Personal Access Token |
| `github_bucket_name` | MinIO bucket name for crawled data |

---

## MinIO / AiStor

Access the MinIO console at:

```
http://localhost:9001
```

Login with `MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD` from your `.env`.

Parquet files are stored at:

```
github-data/
└── repositories/
│   └── year=2025/month=03/day=11/
│       └── github_repository_000000000001_000000120000.parquet
└── users/
    └── year=2025/month=03/day=11/
        └── github_user_000000000001_000000120000.parquet
```

---

## Security Notes

- `.env` is in `.gitignore` — **never commit it**
- All passwords are randomly generated on every `--force` reset and `--rotate`
- The `secrets` MongoDB collection is the **single source of truth** for runtime credentials — the DAG always reads from here, never directly from `.env`
- Use `--rotate` in production to safely rotate credentials without any downtime or data loss
- Use `--force` only when you need a clean slate (e.g. corrupted state, first-time setup)

---
