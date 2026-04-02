"""
Unified GitHub Crawler
Crawls GitHub repositories or users
Stores raw data in minio as Parquet files
"""

import json
import time
from datetime import datetime, timedelta, timezone
from io import BytesIO
from os import getenv

import pandas as pd
import requests
from airflow import DAG
from airflow.providers.standard.operators.python import PythonOperator
from airflow.utils.log.logging_mixin import LoggingMixin
from dotenv import load_dotenv
from github.utils.crawler_utils import decode_state_key, get_crawler_state
from minio import Minio
from pymongo import MongoClient
from pymongo.errors import PyMongoError

# from utils.sentry_config import init_sentry

# init_sentry()
load_dotenv()
logger = LoggingMixin().log
PROJECT_NAME = getenv("PROJECT_NAME")
MONGO_USER = getenv("MONGO_USER")
MONGO_PASSWORD = getenv("MONGO_PASSWORD")
mongo_client = MongoClient(f"mongodb://{MONGO_USER}:{MONGO_PASSWORD}@mongodb:27017/")
mongo_db = mongo_client[PROJECT_NAME]


def flatten_repository(repository: dict) -> dict:
    """Flatten repository data for Parquet"""
    return {
        "id": repository.get("id"),
        "node_id": repository.get("node_id"),
        "name": repository.get("name"),
        "full_name": repository.get("full_name"),
        "private": repository.get("private"),
        "owner_id": repository.get("owner", {}).get("id"),
        "owner_node_id": repository.get("owner", {}).get("node_id"),
        "description": repository.get("description"),
        "fork": repository.get("fork"),
    }


def flatten_user(user: dict) -> dict:
    """Flatten user data for Parquet"""
    return {
        "id": user.get("id"),
        "login": user.get("login"),
        "node_id": user.get("node_id"),
        "avatar_url": user.get("avatar_url"),
        "gravatar_id": user.get("gravatar_id"),
        "url": user.get("url"),
        "html_url": user.get("html_url"),
        "type": user.get("type"),
        "user_view_type": user.get("user_view_type"),
        "site_admin": user.get("site_admin"),
    }


def save_to_minio_parquet(
    secrets: dict,
    crawler_state: dict,
    items: list[dict],
    start_id: int,
    end_id: int,
    minio_client: Minio,
) -> dict:
    """Save data to MinIO as Parquet with partitioning. Returns file metadata."""
    # Filter out None values as a safety measure
    valid_items = [
        item for item in items if item is not None and isinstance(item, dict)
    ]

    if len(valid_items) < len(items):
        logger.warning(
            "Filtered out invalid items in save_to_minio_parquet",
            extra={
                "total_count": len(items),
                "valid_count": len(valid_items),
                "filtered_count": len(items) - len(valid_items),
            },
        )

    if not valid_items:
        logger.warning("No valid items to save, skipping MinIO write")
        return {
            "minio_key": "",
            "size": 0,
            "row_count": 0,
        }

    # Create MinIO key with partitioning
    now = datetime.now(timezone.utc)
    filename_prefix = crawler_state["organisation"] + "_" + crawler_state["entity"]
    minio_key = (
        f"raw/{crawler_state['entity']}/"
        f"year={now.year}/month={now.month:02d}/day={now.day:02d}/"
        f"{filename_prefix}_{start_id}_{end_id}.parquet"
    )

    try:
        # Flatten nested structures based on type
        flattened_items = []

        logger.info(f"Flattening {crawler_state['entity']} items")
        if crawler_state["entity"] == "repository":
            flattened_items = [flatten_repository(item) for item in valid_items]
        elif crawler_state["entity"] == "user":
            flattened_items = [flatten_user(item) for item in valid_items]

        # Convert to DataFrame
        df = pd.DataFrame(flattened_items)

        # Convert to Parquet in memory
        parquet_buffer = BytesIO()
        df.to_parquet(
            parquet_buffer,
            engine="pyarrow",
            compression="snappy",
            index=False,
        )
        parquet_buffer.seek(0)

        # Upload to MinIO
        github_bucket = secrets.get("bucket_name", "github-data")
        logger.info(f"Uploading to MinIO: {minio_key}")
        minio_client.put_object(
            bucket_name=github_bucket,
            object_name=minio_key,
            data=parquet_buffer,
            length=len(parquet_buffer.getvalue()),
            content_type="application/octet-stream",
            metadata={
                "start_id": str(start_id),
                "end_id": str(end_id),
                "count": str(len(valid_items)),
                "format": "parquet",
                "compression": "snappy",
                "entity": crawler_state["entity"],
            },
        )

        logger.info(
            "Saved to MinIO",
            extra={
                "count": len(valid_items),
                "minio_key": minio_key,
                "size_bytes": len(parquet_buffer.getvalue()),
            },
        )

        return {
            "minio_key": minio_key,
            "size": len(parquet_buffer.getvalue()),
            "row_count": len(valid_items),
        }

    except Exception as e:
        logger.error(
            "Failed to write to MinIO", extra={"error": str(e), "minio_key": minio_key}
        )
        raise


def handle_response(response, retry_count, max_retries):
    if response.status_code == 200:
        return response.json(), True, False
    if response.status_code == 403:
        logger.warning(
            "Rate limit exceeded",
            extra={"rate_limit_reset": response.headers.get("X-RateLimit-Reset")},
        )
        if retry_count < max_retries:
            backoff_time = 2**retry_count
            logger.info(
                "Retrying after backoff",
                extra={"backoff_seconds": backoff_time, "attempt": retry_count + 1},
            )
            time.sleep(backoff_time)
            return None, False, True
        return None, True, False
    if response.status_code >= 500:
        logger.warning(
            "GitHub API server error", extra={"status_code": response.status_code}
        )
        if retry_count < max_retries:
            backoff_time = 2**retry_count
            logger.info(
                "Retrying after backoff",
                extra={"backoff_seconds": backoff_time, "attempt": retry_count + 1},
            )
            time.sleep(backoff_time)
            return None, False, True
        logger.info(
            "GitHub API server error",
            extra={"status_code": response.status_code, "body": response.text[:500]},
        )
        return None, True, False

    return None, True, False


def fetch_data(
    crawler_state: dict, since_id: int, github_token: str, max_retries: int = 3
) -> tuple[list[dict] | None, dict]:
    """
    Fetch data from GitHub API with exponential backoff retry
    Returns (list of items or None on error, request_metrics)
    """
    headers = {
        "Authorization": f"token {github_token}",
        "Accept": "application/vnd.github.v3+json",
        "User-Agent": f"{PROJECT_NAME}-GithubCrawler",
    }

    url = f"{crawler_state['endpoint']}?since={since_id}&per_page=100"

    result = None
    request_metrics = {
        "since_id": since_id,
        "request_start": None,
        "request_end": None,
        "retrieval": 0,
        "status_code": 0,
        "rate_limit_remaining": 0,
        "rate_limit": 0,
        "rate_limit_reset": 0,
    }

    for retry_count in range(max_retries + 1):
        try:
            request_metrics["request_start"] = datetime.now(timezone.utc).isoformat()
            response = requests.get(url, headers=headers, timeout=30)
            request_metrics["request_end"] = datetime.now(timezone.utc).isoformat()
            request_metrics["status_code"] = response.status_code

            # Log rate limit info
            rate_limit_remaining = response.headers.get("X-RateLimit-Remaining")
            rate_limit = response.headers.get("X-RateLimit-Limit")
            rate_limit_reset = response.headers.get("X-RateLimit-Reset")

            request_metrics["rate_limit_remaining"] = int(rate_limit_remaining or 0)
            request_metrics["rate_limit"] = int(rate_limit or 0)
            request_metrics["rate_limit_reset"] = int(rate_limit_reset or 0)

            logger.info(
                "GitHub API response",
                extra={
                    "status_code": response.status_code,
                    "rate_limit_remaining": rate_limit_remaining,
                    "rate_limit_reset": rate_limit_reset,
                },
            )

            result, should_break, should_continue = handle_response(
                response, retry_count, max_retries
            )
            if should_break:
                break
            if should_continue:
                continue

        except requests.exceptions.Timeout:
            request_metrics["request_end"] = datetime.now(timezone.utc).isoformat()
            logger.warning("Request timeout")
            if retry_count < max_retries:
                backoff_time = 2**retry_count
                logger.info(
                    "Retrying after backoff",
                    extra={"backoff_seconds": backoff_time, "attempt": retry_count + 1},
                )
                time.sleep(backoff_time)
                continue
            break
        except requests.exceptions.RequestException as e:
            request_metrics["request_end"] = datetime.now(timezone.utc).isoformat()
            logger.error("Request failed", extra={"error": str(e)})
            if retry_count < max_retries:
                backoff_time = 2**retry_count
                logger.info(
                    "Retrying after backoff",
                    extra={"backoff_seconds": backoff_time, "attempt": retry_count + 1},
                )
                time.sleep(backoff_time)
                continue
            break

    if result:
        request_metrics["retrieval"] = len(result)

    return result, request_metrics


def crawl(
    secrets: dict,
    crawler_state: dict,
    start_id: int,
    num_requests: int,
    github_token: str,
    context,
    minio_client: Minio,
) -> tuple[int, int, list[dict], list[dict]]:
    """
    Execute the crawl loop with pacing
    Returns (last_processed_id, total_items_fetched, request_metrics_list, minio_files_list)
    """
    current_id = start_id
    total_items = 0
    batch_items = []
    batch_start_id = start_id

    request_metrics_list = []
    minio_files_list = []

    for i in range(num_requests):
        # Check remaining time (stop 30 seconds before timeout)
        remaining_time = context.get_remaining_time_in_millis() / 1000
        if remaining_time < 30:
            logger.info(
                "Approaching timeout, stopping early",
                extra={"request_number": i + 1, "total_requests": num_requests},
            )
            break

        # Fetch data
        items, req_metrics = fetch_data(crawler_state, current_id, github_token)
        request_metrics_list.append(req_metrics)

        if items is None:
            logger.warning(
                f"Failed to fetch {crawler_state['entity']} items",
                extra={"current_id": current_id},
            )
            time.sleep(crawler_state["sleep_interval"])
            continue

        if len(items) == 0:
            logger.info("No more items returned, reached end of dataset")
            break

        # Filter out None values and invalid items
        valid_items = [
            item
            for item in items
            if item is not None and isinstance(item, dict) and "id" in item
        ]

        if len(valid_items) == 0:
            logger.warning(
                "No valid items in response",
                extra={"current_id": current_id, "raw_count": len(items)},
            )
            time.sleep(crawler_state["sleep_interval"])
            continue

        if len(valid_items) < len(items):
            logger.warning(
                "Filtered out invalid items",
                extra={
                    "total_received": len(items),
                    "valid_count": len(valid_items),
                    "filtered_count": len(items) - len(valid_items),
                },
            )

        # Add to batch
        batch_items.extend(valid_items)
        total_items += len(valid_items)

        # Update current_id to the last item ID in this batch
        last_item_id = valid_items[-1]["id"]
        current_id = last_item_id

        logger.debug(
            "Fetched batch",
            extra={
                "request_number": i + 1,
                "items_count": len(valid_items),
                "last_processed_id": last_item_id,
            },
        )

        # Save batch to MinIO every 10 requests (approximately 1000 items)
        if (i + 1) % 10 == 0 and batch_items:
            file_meta = save_to_minio_parquet(
                secrets,
                crawler_state,
                batch_items,
                batch_start_id,
                current_id,
                minio_client,
            )
            minio_files_list.append(file_meta)
            batch_items = []
            batch_start_id = current_id + 1

        # Pace requests
        time.sleep(crawler_state["sleep_interval"])

    # Save any remaining items in the batch
    if batch_items:
        file_meta = save_to_minio_parquet(
            secrets,
            crawler_state,
            batch_items,
            batch_start_id,
            current_id,
            minio_client,
        )
        minio_files_list.append(file_meta)

    return current_id, total_items, request_metrics_list, minio_files_list


def update_bookmark(
    state_key: str,
    last_processed_id: int,
    total_processed: int,
) -> dict:
    """Synchronously update the bookmark in MongoDB"""

    # Validate state_key format
    organisation, entity = decode_state_key(state_key)
    collection = mongo_db["crawler_state"]

    try:
        updated_at = datetime.now(timezone.utc).isoformat()
        result = collection.update_one(
            {"state_key": state_key},
            {
                "$set": {
                    "last_processed_id": last_processed_id,
                    "total_processed": total_processed,
                    "updated_at": updated_at,
                }
            },
        )

        logger.info(
            f"Updated bookmark for {organisation}/{entity}",
            extra={
                "last_processed_id": last_processed_id,
                "total_processed": total_processed,
                "updated_at": updated_at,
            },
        )

        return {"updated": result.modified_count > 0}

    except PyMongoError as e:
        logger.error("Failed to update MongoDB bookmark", extra={"error": str(e)})
        raise


def run_crawler_task(**kwargs):
    """
    Airflow task handler.
    """

    run_id = kwargs.get("run_id", f"manual_{int(time.time())}")
    logger.info(f"Processing aggregation for {run_id}")

    state_key = (
        kwargs.get("dag_run").conf.get("state_key") if kwargs.get("dag_run") else None
    )

    if not state_key:
        logger.error("Missing state_key in DAG run configuration")
        raise ValueError(
            "Missing state_key in DAG conf. Trigger with: {'state_key': 'U1RBVEUjZ2l0aHViI3JlcG9zaXRvcnk='} for repositories"
        )

    # Decode state_key to get organisation and entity
    organisation, entity = decode_state_key(state_key)
    logger.info(f"Processing aggregation for {organisation}/{entity}")

    try:
        # Get configuration and secrets from MongoDB
        mongo_data = get_crawler_state(state_key)
        crawler_state = mongo_data["crawler_state"]
        secrets = mongo_data["secrets"]

        logger.info(f"Configuration: {crawler_state}")

        # Start from last processed ID for incremental crawling
        start_id = crawler_state["last_processed_id"]

        # Get GitHub token from secrets
        GB_TOKEN = secrets.get("github_token")
        if not GB_TOKEN:
            logger.error("GB_TOKEN not found in DB config.")
            raise ValueError("GitHub token is not configured.")

        logger.info(f"Starting GitHub {crawler_state['entity']} crawler")

        # Initialize dynamically configured MinIO client
        minio_user = secrets.get("minio_user")
        minio_pass = secrets.get("minio_pass")

        minio_client = Minio(
            "aistor:9000",
            access_key=minio_user,
            secret_key=minio_pass,
            secure=False,
        )

        try:
            github_bucket = secrets.get("bucket_name", "github-data")
            if not minio_client.bucket_exists(github_bucket):
                minio_client.make_bucket(github_bucket)
        except Exception as e:
            logger.error(f"Could not verify MinIO bucket during task execution: {e}")
            raise ValueError("MinIO bucket not configured.")

        logger.info(f"MinIO client initialized: {minio_client}")

        # Execute crawl
        class MockLambdaContext:
            def get_remaining_time_in_millis(self):
                return 300000

        last_processed_id, total_fetched, requests_metrics, minio_files = crawl(
            secrets,
            crawler_state,
            start_id,
            crawler_state["requests_per_execution"],
            GB_TOKEN,
            MockLambdaContext(),
            minio_client,
        )

        # Update bookmark
        if last_processed_id > start_id:
            new_total = crawler_state["total_processed"] + total_fetched
            update_bookmark(
                state_key,
                last_processed_id,
                new_total,
            )

            logger.info(
                "Crawl complete",
                extra={
                    "run_id": run_id,
                    "start_id": start_id,
                    "last_processed_id": last_processed_id,
                    "items_fetched": total_fetched,
                    "total_processed": new_total,
                },
            )
            try:
                now = datetime.now(timezone.utc)
                filename_prefix = (
                    crawler_state["organisation"] + "_" + crawler_state["entity"]
                )
                metadata_key = (
                    f"telemetry/{crawler_state['entity']}/"
                    f"year={now.year}/month={now.month:02d}/day={now.day:02d}/"
                    f"{filename_prefix}_{run_id}.json"
                )

                full_metadata = {
                    "run_id": run_id,
                    "run_metadata": {
                        "organisation": crawler_state["organisation"],
                        "entity": crawler_state["entity"],
                        "retrieval": total_fetched,
                        "request_count": len(requests_metrics),
                        "start_id": start_id,
                        "last_processed_id": last_processed_id,
                        "total_processed": new_total,
                    },
                    "requests": requests_metrics,
                    "minio_files": minio_files,
                }

                metadata_bytes = json.dumps(full_metadata).encode("utf-8")
                metadata_buffer = BytesIO(metadata_bytes)
                minio_client.put_object(
                    bucket_name=github_bucket,
                    object_name=metadata_key,
                    data=metadata_buffer,
                    length=len(metadata_bytes),
                    content_type="application/json",
                )

            except Exception as e:
                logger.error(
                    "Failed to save metadata",
                    extra={"error": str(e)},
                )

            mongo_client.close()
            return (
                f"Success: Fetched {total_fetched} items. Last ID: {last_processed_id}"
            )

        logger.warning("No progress made in this execution")
        return "No progress made"

    except Exception:
        logger.exception("Fatal error in crawler")
        raise


# ---------------------------------------------------------------------------------
# AIRFLOW DAG DEFINITION
# ---------------------------------------------------------------------------------

default_args = {
    "owner": "Precious",
    "depends_on_past": False,
    "email_on_failure": False,
    "email_on_retry": False,
    "retries": 1,
    "retry_delay": timedelta(minutes=1),
}

with DAG(
    "github_crawler_v1",
    default_args=default_args,
    description="A Unified GitHub Crawler Pipeline V1",
    schedule=None,
    start_date=datetime(2023, 1, 1),
    catchup=False,
    tags=["github", "crawler"],
) as dag:
    crawl_task = PythonOperator(
        task_id="execute_crawl", python_callable=run_crawler_task
    )

    crawl_task
