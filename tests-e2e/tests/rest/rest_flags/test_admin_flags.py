from src.env_vars import DEFAULT_NWAKU
from src.libs.custom_logger import get_custom_logger
from src.node.waku_node import WakuNode

logger = get_custom_logger(__name__)


class TestAdminFlags:
    def test_admin_set_all_log_levels(self):
        self.node1 = WakuNode(DEFAULT_NWAKU, f"node1_{self.test_id}")
        self.node1.start(relay="true")
        levels = ["TRACE", "DEBUG", "INFO", "NOTICE", "WARN", "ERROR", "FATAL"]
        for lvl in levels:
            resp = self.node1.set_log_level(lvl)
            logger.debug(f"Set log level ({lvl}) -> status={resp.status_code}")
            assert resp.status_code == 200, f"failed to set log level {lvl} {resp.text}"

        resp = self.node1.set_log_level("TRACE")
        logger.debug(f"Restore default log level (TRACE) -> status={resp.status_code}")
        assert resp.status_code == 200, f"failed to revert log level: {resp.text}"
