import base64
import os

from airflow.utils.log.logging_mixin import LoggingMixin
from pymongo import MongoClient

logger = LoggingMixin().log


def decode_state_key(state_key: str) -> tuple[str, str]:
    """
    Decode state_key to extract organisation and entity.
    Format: STATE#{organisation}#{entity}
    """
    try:
        decoded_key = base64.b64decode(state_key).decode("utf-8")
        parts = decoded_key.split("#")
        if len(parts) != 3:
            raise ValueError("Invalid state_key format")
        return parts[1], parts[2]
    except Exception as e:
        logger.warning(f"Failed to decode state_key: {e}")
        raise ValueError("Invalid state_key format") from e


def get_crawler_config(state_key: str) -> dict:
    """
    Fetches the crawler configuration from MongoDB using the state_key.
    """
    MONGO_USER = os.environ.get("MONGO_USER")
    MONGO_PASSWORD = os.environ.get("MONGO_PASSWORD")

    client = MongoClient(f"mongodb://{MONGO_USER}:{MONGO_PASSWORD}@mongodb:27017/")
    db = client["DataReaper"]
    collection = db["crawler_config"]

    config = collection.find_one({"state_key": state_key})

    if not config:
        raise ValueError(
            f"Crawler config not found in MongoDB for state_key: {state_key}"
        )

    # Automatically map secrets directly into the config dictionary
    secrets_collection = db["secrets"]
    secrets = secrets_collection.find_one({"env": "global"}) or {}

    config["project_name"] = secrets.get("project_name")
    config["minio_user"] = secrets.get("minio_user")
    config["minio_pass"] = secrets.get("minio_pass")
    config["github_token"] = secrets.get("github_token")
    config["bucket_name"] = secrets.get("bucket_name")

    return config
