import re
import subprocess
from src.env_vars import NETWORK_NAME
from src.libs.custom_logger import get_custom_logger

logger = get_custom_logger(__name__)


class TrafficController:
    def _pid(self, node) -> int:
        if not node.container:
            raise RuntimeError("Node container not started yet")

        node.container.reload()
        pid = node.container.attrs.get("State", {}).get("Pid")
        if not pid or pid == 0:
            raise RuntimeError("Container PID not available (container not running?)")
        return int(pid)

    def _exec(self, node, tc_args: list[str], iface: str = "eth0"):
        pid = self._pid(node)

        cmd = ["sudo", "-n", "nsenter", "-t", str(pid), "-n", "tc"] + tc_args
        logger.info(f"TC exec: {cmd}")

        res = subprocess.run(cmd, capture_output=True, text=True)
        if res.returncode != 0:
            raise RuntimeError(f"TC failed: {' '.join(cmd)}\n" f"stdout: {res.stdout}\n" f"stderr: {res.stderr}")

        return res.stdout

    def log_tc_stats(self, node, iface: str = "eth0"):
        """
        Log tc statistics for an interface (best-effort).
        Useful to confirm netem loss/delay counters (sent/dropped/etc.).
        """
        try:
            out = self._exec(node, ["-s", "qdisc", "show", "dev", iface], iface=iface)
            out = (out or "").strip()
            if out:
                logger.debug(f"tc -s qdisc show dev {iface}:\n{out}")
            else:
                logger.debug(f"tc -s qdisc show dev {iface}: (no output)")
        except Exception as e:
            logger.debug(f"Failed to read tc stats for {iface}: {e}")

    def clear(self, node, iface: str = "eth0"):
        try:
            self._exec(node, ["qdisc", "del", "dev", iface, "root"], iface=iface)
        except RuntimeError as e:
            msg = str(e)
            if "Cannot delete qdisc with handle of zero" in msg or "No such file or directory" in msg:
                return
            raise

    def add_latency(self, node, ms: int, iface: str = "eth0"):
        self.clear(node, iface=iface)
        self._exec(node, ["qdisc", "add", "dev", iface, "root", "netem", "delay", f"{ms}ms"], iface=iface)

    def add_packet_loss(self, node, percent: float, iface: str = "eth0"):
        self.clear(node, iface=iface)

        self._exec(
            node,
            ["qdisc", "add", "dev", iface, "root", "netem", "loss", f"{percent}%"],
            iface=iface,
        )
        try:
            stats = self._exec(node, ["-s", "qdisc", "show", "dev", iface], iface=iface)
            if stats is not None:
                if isinstance(stats, (bytes, bytearray)):
                    stats = stats.decode(errors="replace")
                logger.debug(f"tc -s qdisc show dev {iface}:\n{stats}")
            else:
                logger.debug(f"Executed: tc -s qdisc show dev {iface} (no output returned by _exec)")
        except Exception as e:
            logger.debug(f"Failed to read tc stats for {iface}: {e}")

    def add_bandwidth(self, node, rate: str, iface: str = "eth0"):
        self.clear(node, iface=iface)
        self._exec(
            node,
            ["qdisc", "add", "dev", iface, "root", "tbf", "rate", rate, "burst", "32kbit", "limit", "12500"],
            iface=iface,
        )

    def add_packet_loss_correlated(
        self,
        node,
        percent: float,
        correlation: float,
        iface: str = "eth0",
    ):
        self.clear(node, iface=iface)
        self._exec(
            node,
            [
                "qdisc",
                "add",
                "dev",
                iface,
                "root",
                "netem",
                "loss",
                f"{percent}%",
                f"{correlation}%",
            ],
            iface=iface,
        )

    def add_packet_reordering(
        self,
        node,
        percent: int = 25,
        correlation: int = 50,
        delay_ms: int = 10,
        iface: str = "eth0",
    ):
        self.clear(node, iface=iface)

        self._exec(
            node,
            [
                "qdisc",
                "add",
                "dev",
                iface,
                "root",
                "netem",
                "delay",
                f"{delay_ms}ms",
                "reorder",
                f"{percent}%",
                f"{correlation}%",
            ],
            iface=iface,
        )

    def _p2p_iface(self, node) -> str:
        """
        Return the name of the container interface attached to the waku
        network (where libp2p traffic flows).

        DockerManager attaches each node to two networks: the default bridge
        (where host-published ports land, typically `eth0`) and the waku
        network (where inter-container libp2p/gossipsub traffic flows, typically
        `eth1`). tc on the default bridge only affects REST control plane; for
        a packet loss test targeting libp2p we need the waku interface.

        This helper resolves the correct interface by looking up the node's
        waku-network IP via Docker and matching it against `ip -o -4 addr`
        output from inside the container.
        """
        if not node.container:
            raise RuntimeError("Node container not started yet")
        node.container.reload()
        networks = node.container.attrs.get("NetworkSettings", {}).get("Networks", {})
        waku_net = networks.get(NETWORK_NAME)
        if not waku_net or not waku_net.get("IPAddress"):
            raise RuntimeError(f"Container is not attached to the '{NETWORK_NAME}' docker network")
        waku_ip = waku_net["IPAddress"]

        exit_code, output = node.container.exec_run(["ip", "-o", "-4", "addr"])
        if exit_code != 0:
            raise RuntimeError(f"ip addr failed inside container: {output}")
        for line in output.decode().splitlines():
            if f" {waku_ip}/" in line:
                tokens = line.split()
                if len(tokens) >= 2:
                    return tokens[1]
        raise RuntimeError(f"No interface inside container holds waku IP {waku_ip}")

    def dropped_packets_p2p(self, node) -> int:
        iface = self._p2p_iface(node)
        stats = self._exec(node, ["-s", "qdisc", "show", "dev", iface], iface=iface)
        counter = re.search(r"dropped (\d+)", stats)
        if not counter:
            raise RuntimeError(f"No packet counters for {iface}: {stats}")
        return int(counter.group(1))

    def clear_p2p(self, node):
        """
        Remove any tc rule previously installed on the node's waku (libp2p)
        interface.
        """
        self.clear(node, iface=self._p2p_iface(node))

    def add_packet_loss_p2p_only(self, node, percent: float):
        """
        Apply uncorrelated packet loss to the waku (libp2p) network interface
        of a node. REST API traffic rides a separate docker interface and is
        not affected, so the test harness's control plane stays reliable.
        """
        iface = self._p2p_iface(node)
        self.clear(node, iface=iface)
        self._exec(node, f"qdisc add dev {iface} root netem loss {percent}%".split(), iface=iface)

    def add_latency_p2p_only(self, node, ms: int):
        self.add_latency(node, ms, iface=self._p2p_iface(node))

    def add_bandwidth_p2p_only(self, node, rate: str):
        self.add_bandwidth(node, rate, iface=self._p2p_iface(node))

    def add_packet_loss_correlated_p2p_only(self, node, percent: float, correlation: float):
        """
        Correlated packet loss on the waku (libp2p) network interface. See
        add_packet_loss_p2p_only for why REST stays unaffected.
        """
        iface = self._p2p_iface(node)
        self.clear(node, iface=iface)
        self._exec(
            node,
            f"qdisc add dev {iface} root netem loss {percent}% {correlation}%".split(),
            iface=iface,
        )
