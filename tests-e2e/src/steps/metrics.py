import re
from src.libs.custom_logger import get_custom_logger
import allure
from tenacity import retry, stop_after_delay, wait_fixed

from src.test_data import METRICS_WITH_INITIAL_VALUE_ZERO


logger = get_custom_logger(__name__)


class StepsMetrics:
    @allure.step
    def check_metric(self, node, metric_name, expected_value, exact=False):
        logger.debug(f"Checking metric: {metric_name} has {expected_value}")
        response = node.get_metrics()
        lines = response.split("\n")
        actual_value = None
        for line in lines:
            if line.startswith(metric_name):
                parts = line.split(" ")
                if len(parts) >= 2:
                    actual_value = float(parts[1])
                    break
        if actual_value is None:
            raise AttributeError(f"Metric '{metric_name}' not found")
        logger.debug(f"Found metric: {metric_name} with value {actual_value}")
        if exact:
            assert actual_value == expected_value, f"Expected value for '{metric_name}' is {expected_value}, but got {actual_value}"
        else:
            assert actual_value >= expected_value, f"Expected value for '{metric_name}' is >= {expected_value}, but got {actual_value}"

    @allure.step
    def wait_for_metric(self, node, metric_name, expected_value, timeout_duration=90, exact=False):
        @retry(stop=stop_after_delay(timeout_duration), wait=wait_fixed(1), reraise=True)
        def check_metric_with_retry():
            self.check_metric(node, metric_name, expected_value, exact=exact)

        check_metric_with_retry()

    def validate_initial_metrics(self, node):
        metrics_data = node.get_metrics()

        # Regular expression to match metric lines, accounting for optional labels
        metric_pattern = re.compile(r"^(?P<metric_name>[a-zA-Z0-9_:]+(?:{[^}]+})?)\s+(?P<value>[0-9]+\.?[0-9]*)$", re.MULTILINE)

        # Dictionary to store the metrics and their values
        metrics_dict = {}
        for match in metric_pattern.finditer(metrics_data):
            metric_name = match.group("metric_name")
            value = float(match.group("value"))
            metrics_dict[metric_name] = value

        errors = []
        # Assert that specific metrics have a value of 0.0
        for metric in METRICS_WITH_INITIAL_VALUE_ZERO:
            if metric not in metrics_dict:
                errors.append(f"Metric {metric} is missing from the metrics data")
            elif metrics_dict[metric] != 0.0:
                errors.append(f"Expected {metric} to be 0.0, but got {metrics_dict[metric]}")

        # Assert that all other metrics have a value greater than 0.0
        for metric, value in metrics_dict.items():
            if metric not in METRICS_WITH_INITIAL_VALUE_ZERO and value <= 0.0:
                errors.append(f"Expected {metric} to have a positive value, but got {value}")

        assert not errors, f"Metrics validation failed:\n" + "\n".join(errors)
        logger.debug(f"All metrics are present and have valid values.")
