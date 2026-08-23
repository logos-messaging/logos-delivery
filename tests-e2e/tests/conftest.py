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
from src.libs.common import attach_allure_file
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


# See https://docs.pytest.org/en/latest/example/simple.html#making-test-result-information-available-in-fixtures
@pytest.hookimpl(hookwrapper=True, tryfirst=True)
def pytest_runtest_makereport(item):
    outcome = yield
    rep = outcome.get_result()
    if rep.when == "call":
        setattr(item, "rep_call", rep)
        return rep
    return None


@pytest.fixture(scope="session", autouse=True)
def set_allure_env_variables():
    yield
    if os.path.isdir("allure-results") and not os.path.isfile(os.path.join("allure-results", "environment.properties")):
        logger.debug(f"Running fixture teardown: {inspect.currentframe().f_code.co_name}")
        with open(os.path.join("allure-results", "environment.properties"), "w") as outfile:
            for attribute_name in dir(env_vars):
                if attribute_name.isupper():
                    attribute_value = getattr(env_vars, attribute_name)
                    outfile.write(f"{attribute_name}={attribute_value}\n")


@pytest.fixture(scope="function", autouse=False)
def start_postgres_container():
    pg_container = start_postgres()
    yield
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
def attach_logs_on_fail(request):
    yield
    if env_vars.RUNNING_IN_CI and hasattr(request.node, "rep_call") and request.node.rep_call.failed:
        logger.debug(f"Running fixture teardown: {inspect.currentframe().f_code.co_name}")
        logger.debug("Test failed, attempting to attach logs to the allure reports")
        for file in glob.glob(os.path.join(env_vars.DOCKER_LOG_DIR, "*" + request.cls.test_id + "*")):
            attach_allure_file(file)


@pytest.fixture(scope="function", autouse=True)
def close_open_nodes(attach_logs_on_fail):
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
