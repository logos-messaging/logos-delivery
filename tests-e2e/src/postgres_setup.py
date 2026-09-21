import docker
from src.env_vars import NETWORK_NAME, PG_PASS, PG_USER
from src.libs.custom_logger import get_custom_logger

logger = get_custom_logger(__name__)


def start_postgres():
    pg_env = {"POSTGRES_USER": PG_USER, "POSTGRES_PASSWORD": PG_PASS}

    client = docker.from_env()

    postgres_container = client.containers.run(
        "postgres:15.4-alpine3.18",
        name="postgres",
        environment=pg_env,
        command="postgres",
        ports={"5432/tcp": ("127.0.0.1", 5432)},
        restart_policy={"Name": "on-failure", "MaximumRetryCount": 5},
        healthcheck={
            "Test": ["CMD-SHELL", "pg_isready -U postgres -d postgres"],
            "Interval": 30000000000,  # 30 seconds in nanoseconds
            "Timeout": 60000000000,  # 60 seconds in nanoseconds
            "Retries": 5,
            "StartPeriod": 80000000000,  # 80 seconds in nanoseconds
        },
        detach=True,
        network_mode=NETWORK_NAME,
    )

    logger.debug("Postgres container started")

    return postgres_container


def stop_postgres(postgres_container):
    postgres_container.stop()
    postgres_container.remove(v=True)
    logger.debug("Postgres container stopped and removed.")
