import docker
from src.env_vars import NETWORK_NAME, PG_PASS, PG_USER
from src.libs.common import wait_until
from src.libs.custom_logger import get_custom_logger
from src.node.docker_mananger import DockerManager

logger = get_custom_logger(__name__)


def start_postgres():
    pg_env = {"POSTGRES_USER": PG_USER, "POSTGRES_PASSWORD": PG_PASS}
    image = "postgres:15.4-alpine3.18"

    DockerManager(image).create_network()
    client = docker.from_env()

    postgres_container = client.containers.create(
        image,
        name="postgres",
        environment=pg_env,
        command="postgres",
        restart_policy={"Name": "on-failure", "MaximumRetryCount": 5},
        healthcheck={
            "Test": ["CMD-SHELL", "pg_isready -U postgres -d postgres"],
            "Interval": 30000000000,  # 30 seconds in nanoseconds
            "Timeout": 60000000000,  # 60 seconds in nanoseconds
            "Retries": 5,
            "StartPeriod": 80000000000,  # 80 seconds in nanoseconds
        },
        network_mode=NETWORK_NAME,
    )

    try:
        postgres_container.start()
        # The server that initialises the database listens on the Unix socket only, so only the final server answers over TCP.
        wait_until(
            lambda: postgres_container.exec_run(["pg_isready", "-h", "127.0.0.1", "-U", PG_USER]).exit_code == 0,
            timeout_duration=30,
            message="Postgres did not accept connections",
        )
    except Exception:
        stop_postgres(postgres_container)
        raise

    logger.debug("Postgres container started")

    return postgres_container


def get_message_count(postgres_container):
    result = postgres_container.exec_run(["psql", "-U", PG_USER, "-tAc", "SELECT count(*) FROM messages"])
    assert result.exit_code == 0, f"Could not count the stored messages: {result.output.decode()}"
    return int(result.output.decode().strip())


def stop_postgres(postgres_container):
    postgres_container.remove(v=True, force=True)
    logger.debug("Postgres container stopped and removed.")
