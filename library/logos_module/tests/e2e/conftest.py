"""Fixtures for the delivery_module e2e suite.

Two daemon flavours:
  * `solo_daemon` (function scope) — one fresh logoscore container per test, used
    by the single-node lifecycle/query tests. Fresh because createNode is
    once-per-context: a started node can't be re-created, so tests can't share one.
  * `node_a` / `node_b` (module scope) — two daemons in a shared docker network,
    peered directly via staticnodes (node A's container-routable multiaddr), used
    by the two-node delivery tests.

Every prerequisite (docker, the logoscore image, the built module layout) is
gated by `_e2e_env_or_skip`, so the suite skips cleanly when run without setup.
"""

from __future__ import annotations

import os
import subprocess
import sys
import time
import uuid
from collections.abc import Callable, Iterator
from contextlib import ExitStack
from pathlib import Path

import pytest

from libs.constants import NETWORK_SUBNET
from libs.helpers import DeliveryNode, make_delivery_config, node_multiaddr, setup_delivery_node

MESH_STABILIZATION_S = 12.0


def _docker_logs(container_name: str) -> str:
    r = subprocess.run(["docker", "logs", container_name], capture_output=True, text=True)
    return (r.stdout or "") + (r.stderr or "")


def _save_logs(container_name: str) -> None:
    log_dir = Path(os.environ.get("E2E_LOG_DIR", "/tmp"))
    log_dir.mkdir(parents=True, exist_ok=True)
    try:
        (log_dir / f"{container_name}.log").write_text(_docker_logs(container_name))
    except OSError as e:
        sys.stderr.write(f"warning: failed to save log for {container_name}: {e}\n")


@pytest.fixture(scope="session")
def _e2e_env_or_skip() -> tuple[str, Path]:
    """Single gate: skip unless docker, the logoscore image, and the built
    delivery_module layout are all present."""
    from logoscore import docker_available, image_present  # noqa: PLC0415

    if not docker_available():
        pytest.skip("docker not available")
    image = os.environ.get("LOGOSCORE_IMAGE")
    if not image:
        pytest.skip("LOGOSCORE_IMAGE not set")
    if not image_present(image):
        pytest.skip(f"LOGOSCORE_IMAGE={image!r} not present locally")
    modules_dir_env = os.environ.get("LOGOS_MODULES_DIR")
    if not modules_dir_env:
        pytest.skip("LOGOS_MODULES_DIR not set")
    modules_dir = Path(modules_dir_env)
    if not (modules_dir / "delivery_module" / "manifest.json").is_file():
        pytest.skip(
            f"LOGOS_MODULES_DIR={modules_dir} doesn't contain "
            "delivery_module/manifest.json — did you run `nix build .#install-portable`?"
        )
    return image, modules_dir


@pytest.fixture(scope="session")
def shared_docker_network(_e2e_env_or_skip: tuple[str, Path]) -> Iterator[str]:
    name = f"logosdelivery-e2e-{uuid.uuid4().hex[:8]}"
    r = subprocess.run(
        ["docker", "network", "create", "--subnet", NETWORK_SUBNET, name],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        pytest.fail(f"failed to create docker network {name!r}: {r.stderr.strip()}")
    try:
        yield name
    finally:
        subprocess.run(["docker", "network", "rm", name], capture_output=True)


def _new_daemon(image: str, modules_dir: Path, network: str, label: str):
    from logoscore import LogoscoreDockerDaemon  # noqa: PLC0415

    container_name = f"logoscore-{label.lower()}-{uuid.uuid4().hex[:8]}"
    daemon = LogoscoreDockerDaemon(
        image=image,
        modules_dir=modules_dir,
        container_name=container_name,
        network=network,
        startup_timeout=60.0,
        extra_args=["--verbose"],
    )
    return daemon, container_name


@pytest.fixture
def solo_daemon(_e2e_env_or_skip: tuple[str, Path], shared_docker_network: str) -> Iterator:
    """A fresh, started logoscore container — module mounted, nothing loaded yet.
    The test drives load_module/createNode/start/stop itself."""
    image, modules_dir = _e2e_env_or_skip
    daemon, container_name = _new_daemon(image, modules_dir, shared_docker_network, "solo")
    try:
        daemon.start()
        yield daemon
    finally:
        _save_logs(container_name)
        daemon.stop()


@pytest.fixture(scope="module")
def delivery_node_factory(
    _e2e_env_or_skip: tuple[str, Path],
    shared_docker_network: str,
) -> Iterator[Callable[[str, str], DeliveryNode]]:
    """Factory spawning a fully set-up (load+createNode+start) DeliveryNode per
    call. All teardown + log capture is registered on one ExitStack closed when
    the module's tests finish."""
    image, modules_dir = _e2e_env_or_skip

    with ExitStack() as stack:
        def _create(label: str, config_json: str) -> DeliveryNode:
            daemon, container_name = _new_daemon(image, modules_dir, shared_docker_network, label)
            stack.enter_context(daemon)
            stack.callback(_save_logs, container_name)
            return setup_delivery_node(daemon, config_json, label)

        yield _create


@pytest.fixture(scope="module")
def node_a(delivery_node_factory: Callable[[str, str], DeliveryNode]) -> DeliveryNode:
    return delivery_node_factory("A", make_delivery_config())


@pytest.fixture(scope="module")
def node_b(
    delivery_node_factory: Callable[[str, str], DeliveryNode],
    node_a: DeliveryNode,
) -> DeliveryNode:
    peer = node_multiaddr(node_a)
    node = delivery_node_factory("B", make_delivery_config(static_peers=[peer]))
    time.sleep(MESH_STABILIZATION_S)
    return node
