import os
import re
import time
from src.libs.custom_logger import get_custom_logger
import random
import threading
import docker
from src.env_vars import NETWORK_NAME, SUBNET, IP_RANGE, GATEWAY
from docker.types import IPAMConfig, IPAMPool
from docker.errors import NotFound, APIError

logger = get_custom_logger(__name__)


class DockerManager:
    def __init__(self, image):
        self._image = image
        self._client = docker.from_env()
        logger.debug(f"Docker client initialized with image {self._image}")

    def create_network(self, network_name=NETWORK_NAME):
        logger.debug(f"Attempting to create or retrieve network {network_name}")
        networks = self._client.networks.list(names=[network_name])
        if networks:
            logger.debug(f"Network {network_name} already exists")
            return networks[0]

        network = self._client.networks.create(
            network_name,
            driver="bridge",
            ipam=IPAMConfig(driver="default", pool_configs=[IPAMPool(subnet=SUBNET, iprange=IP_RANGE, gateway=GATEWAY)]),
        )
        logger.debug(f"Network {network_name} created")
        return network

    def start_container(self, image_name, ports, args, log_path, container_ip, volumes, remove_container=True):
        cli_args = []
        for key, value in args.items():
            if isinstance(value, list):  # Check if value is a list
                cli_args.extend([f"--{key}={item}" for item in value])  # Add a command for each item in the list
            elif value is None:
                cli_args.append(f"{key}")  # Add simple command as it is passed in the key
            else:
                cli_args.append(f"--{key}={value}")  # Add a single command

        port_bindings = {f"{port}/tcp": ("", port) for port in ports}
        port_bindings_for_log = " ".join(f"-p {port}:{port}" for port in ports)
        cli_args_str_for_log = " ".join(cli_args)
        logger.debug(f"docker run -i -t {port_bindings_for_log} {image_name} {cli_args_str_for_log}")
        container = self._client.containers.run(
            image_name, command=cli_args, ports=port_bindings, detach=True, remove=remove_container, auto_remove=remove_container, volumes=volumes
        )

        network = self._client.networks.get(NETWORK_NAME)
        logger.debug(f"docker network connect --ip {container_ip} {NETWORK_NAME} {container.id}")
        network.connect(container, ipv4_address=container_ip)

        logger.debug(f"Container started with ID {container.short_id}. Setting up logs at {log_path}")
        log_thread = threading.Thread(target=self._log_container_output, args=(container, log_path))
        log_thread.daemon = True
        log_thread.start()

        return container

    def _log_container_output(self, container, log_path):
        os.makedirs(os.path.dirname(log_path), exist_ok=True)
        retry_count = 0
        start_time = time.time()
        try:
            with open(log_path, "wb+") as log_file:
                while True:
                    if container.status in ["exited", "dead"]:
                        logger.info(f"Container {container.short_id} has stopped. Exiting log stream.")
                        return
                    try:
                        for chunk in container.logs(stream=True):
                            if chunk:
                                log_file.write(chunk)
                                log_file.flush()
                                start_time = time.time()
                                retry_count = 0
                            else:
                                if time.time() - start_time > 5:
                                    logger.warning(f"Log stream timeout for container {container.short_id}")
                                    return
                    except (APIError, IOError) as e:
                        retry_count += 1
                        if retry_count >= 5:
                            logger.error(f"Max retries reached for container {container.short_id}. Exiting log stream.")
                            return
                        time.sleep(0.2)
                    except Exception as e:
                        return
        except Exception as e:
            logger.error(f"Failed to set up logging for container {container.short_id}: {e}")

    def generate_ports(self, base_port=None, count=5):
        if base_port is None:
            base_port = random.randint(1024, 65535 - count)
        ports = [str(base_port + i) for i in range(count)]
        logger.debug(f"Generated ports {ports}")
        return ports

    @staticmethod
    def generate_random_ext_ip():
        base_ip_fragments = SUBNET.split(".")[:2]
        ext_ip = ".".join(base_ip_fragments + [str(random.randint(0, 255)) for _ in range(2)])
        logger.debug(f"Generated random external IP {ext_ip}")
        return ext_ip

    def is_container_running(self, container):
        try:
            refreshed_container = self._client.containers.get(container.id)
            return refreshed_container.status == "running"
        except NotFound:
            logger.error(f"Container with ID {container.id} not found")
            return False

    @property
    def image(self):
        return self._image

    def search_log_for_keywords(self, log_path, keywords, use_regex=False):
        matches = {keyword: [] for keyword in keywords}

        # Open the log file and search line by line
        with open(log_path, "r") as log_file:
            for line in log_file:
                for keyword in keywords:
                    if use_regex:
                        if re.search(keyword, line, re.IGNORECASE):
                            matches[keyword].append(line.strip())
                    else:
                        if keyword.lower() in line.lower():
                            matches[keyword].append(line.strip())

        # Check if there were any matches
        if any(matches[keyword] for keyword in keywords):
            for keyword, lines in matches.items():
                if lines:
                    logger.debug(f"Found matches for keyword '{keyword}': {lines}")
            return matches
        else:
            logger.debug("No errors found in the waku logs.")
            return None
