from src.libs.custom_logger import get_custom_logger
import allure
from tenacity import retry, stop_after_delay, wait_fixed


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
