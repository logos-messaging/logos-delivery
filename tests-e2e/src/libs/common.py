import uuid
from datetime import datetime
from time import sleep
from src.libs.custom_logger import get_custom_logger
import os
import base64
import allure
from tenacity import retry, stop_after_delay, wait_fixed

logger = get_custom_logger(__name__)


def bytes_to_hex(byte_array):
    return "".join(format(byte, "02x") for byte in byte_array)


def to_base64(input_data):
    if isinstance(input_data, str):
        input_bytes = input_data.encode()
    elif isinstance(input_data, int):
        input_bytes = str(input_data).encode()
    elif isinstance(input_data, bytes):
        input_bytes = input_data
    else:
        input_bytes = str(input_data).encode()
    base64_encoded = base64.b64encode(input_bytes)
    return base64_encoded.decode()


def to_hex(input_data):
    if isinstance(input_data, str):
        input_bytes = input_data.encode()
    elif isinstance(input_data, int):
        input_bytes = str(input_data).encode()
    elif isinstance(input_data, bytes):
        input_bytes = input_data
    else:
        input_bytes = str(input_data).encode()
    return "0x" + input_bytes.hex()


def attach_allure_file(file):
    logger.debug(f"Attaching file {file}")
    allure.attach.file(file, name=os.path.basename(file), attachment_type=allure.attachment_type.TEXT)


def delay(num_seconds):
    logger.debug(f"Sleeping for {num_seconds} seconds")
    sleep(num_seconds)


def wait_until(condition, timeout_duration=20, time_between_retries=0.5, message=None):
    # Calls condition() until it returns a truthy value, which is returned to the caller.
    # An exception raised by condition() counts as not met yet, and is polled through.
    @retry(stop=stop_after_delay(timeout_duration), wait=wait_fixed(time_between_retries), reraise=True)
    def poll():
        result = condition()
        assert result, message or f"Condition not met within {timeout_duration} seconds"
        return result

    return poll()


def gen_step_id():
    return f"{datetime.now().strftime('%Y-%m-%d_%H-%M-%S')}__{str(uuid.uuid4())}"
