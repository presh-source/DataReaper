import base64
from os import getenv

from airflow.utils.log.logging_mixin import LoggingMixin
from pymongo import MongoClient
from pymongo.errors import PyMongoError

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


def get_crawler_state(state_key: str) -> dict:
    """
    Fetches the crawler configuration from MongoDB using the state_key.
    """
    try:
        MONGO_USER = getenv("MONGO_USER")
        MONGO_PASSWORD = getenv("MONGO_PASSWORD")

        client = MongoClient(f"mongodb://{MONGO_USER}:{MONGO_PASSWORD}@mongodb:27017/")
        mongo_db = client["data-reaper"]
        secret_collection = mongo_db["secrets"]
        config_collection = mongo_db["crawler_state"]

        # Get secrets
        global_secrets = (
            secret_collection.find_one({"env": "global"}, {"_id": 0, "env": 0}) or {}
        )
        github_secrets = (
            secret_collection.find_one({"env": "github"}, {"_id": 0, "env": 0}) or {}
        )

        if not global_secrets and not github_secrets:
            raise ValueError("Secrets not configured in DB")

        # Get crawler config
        crawler_state = config_collection.find_one({"state_key": state_key}, {"_id": 0})

        if not crawler_state:
            raise ValueError(
                f"Crawler config not configured for state_key in DB: {state_key}"
            )

        # Merge secrets and config
        mongo_data = {
            "secrets": {**global_secrets, **github_secrets},
            "crawler_state": crawler_state,
        }

        client.close()
        return mongo_data

    except PyMongoError as e:
        logger.error(f"Failed to get crawler config: {e}")
        raise ValueError("Failed to get crawler config") from e
