# -*- coding: utf-8 -*-
import inspect
import glob
import logging
import sys
from src.libs.custom_logger import get_custom_logger
import os
import pytest
from datetime import datetime
from time import time
from uuid import uuid4
import src.env_vars as env_vars
from src.data_storage import DS
from src.postgres_setup import start_postgres, stop_postgres

logger = get_custom_logger(__name__)


_session_exit_status = None


@pytest.hookimpl(trylast=True)
def pytest_sessionfinish(session, exitstatus):
    global _session_exit_status
    _session_exit_status = int(exitstatus)


@pytest.hookimpl(trylast=True)
def pytest_unconfigure(config):
    # liblogosdelivery threads outlive destroy; finalizing the interpreter under them segfaults.
    if _session_exit_status is None:
        return
    sys.stdout.flush()
    sys.stderr.flush()
    logging.shutdown()
    os._exit(_session_exit_status)


@pytest.fixture(scope="function", autouse=False)
def start_postgres_container():
    pg_container = start_postgres()
    yield pg_container
    stop_postgres(pg_container)


@pytest.fixture(scope="function", autouse=True)
def test_id(request):
    # setting up an unique test id to be used where needed
    logger.debug(f"Running fixture setup: {inspect.currentframe().f_code.co_name}")
    request.cls.test_id = f"{datetime.now().strftime('%Y-%m-%d_%H-%M-%S')}__{str(uuid4())}"


@pytest.fixture(scope="function", autouse=True)
def test_setup(request, test_id):
    logger.debug(f"Running test: {request.node.name} with id: {request.cls.test_id}")
    yield
    logger.debug(f"Running fixture teardown: {inspect.currentframe().f_code.co_name}")
    for file in glob.glob(os.path.join(env_vars.DOCKER_LOG_DIR, "*")):
        if os.path.getmtime(file) < time() - 3600:
            logger.debug(f"Deleting old log file: {file}")
            try:
                os.remove(file)
            except:
                logger.error("Could not delete file")


@pytest.fixture(scope="function", autouse=True)
def close_open_nodes():
    DS.waku_nodes = []
    yield
    logger.debug(f"Running fixture teardown: {inspect.currentframe().f_code.co_name}")
    crashed_containers = []
    for node in DS.waku_nodes:
        try:
            node.stop()
        except Exception as ex:
            if "No such container" in str(ex):
                crashed_containers.append(node.image)
            logger.error(f"Failed to stop container because of error {ex}")
    assert not crashed_containers, f"Containers {crashed_containers} crashed during the test!!!"


@pytest.fixture(scope="function", autouse=True)
def check_waku_log_errors():
    yield
    logger.debug(f"Running fixture teardown: {inspect.currentframe().f_code.co_name}")
    for node in DS.waku_nodes:
        node.check_waku_log_errors()
