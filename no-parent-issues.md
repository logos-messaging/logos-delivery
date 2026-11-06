# logos-delivery — open issues with no GitHub parent (2026-10-07)

53 of 89 open issues have no parent.

## Maintenance and code refactor (31)

Rated 0 (not needed) – 5 (most relevant), surface pass.

| # | Title | Assignee | Priority / action | Rate | Why |
|---|---|---|---|---|---|
| [#4371](https://github.com/logos-messaging/logos-delivery/issues/4371) | Deploy v0.39.0 in status fleet | Ivansete-status | Triage | 5 | current release ops |
| [#4226](https://github.com/logos-messaging/logos-delivery/issues/4226) | Service discovery spams dial failures to unroutable addresses (127.0.0.1/tcp/0, 0.0.0.0) | NagyZoltanPeter |  | 4 | log flood on every node, prod |
| [#1137](https://github.com/logos-messaging/logos-delivery/issues/1137) | feat: Support multiple DNS discovery trees | | P1 | 4 | only last enrtree kept, silently |
| [#4436](https://github.com/logos-messaging/logos-delivery/issues/4436) | question: any --rate-limit entry replaces the default rate limits, so filter falls to 30/1m and unnamed protocols run without a limit | | Triage | 4 | any --rate-limit drops defaults; unnamed protocols unlimited (DoS) |
| [#4078](https://github.com/logos-messaging/logos-delivery/issues/4078) | MIssing data in some grafana dashboards | igor-sirotin |  | 3 | missing prod monitoring data |
| [#4044](https://github.com/logos-messaging/logos-delivery/issues/4044) | standardize the use of Persistence | NagyZoltanPeter |  | 3 | tech debt; now carries #2792/#2798 reqs |
| [#3231](https://github.com/logos-messaging/logos-delivery/issues/3231) | bug: possible issue where-in filter push fails to a lightclient on ip address change of the client | | P2 | 3 | reproduced locally; simple fix proposed (newest-conn push + limit 2) |
| [#1558](https://github.com/logos-messaging/logos-delivery/issues/1558) | chore: match CLI argument and environment variable serialization | | Triage | 3 | env vars hex-decoded: `=true` fails, ints garbled |
| [#3165](https://github.com/logos-messaging/logos-delivery/issues/3165) | bug: inconsistency in contentTopic generation | | P2 | 2 | cross-client autosharding mismatch; verify |
| [#1288](https://github.com/logos-messaging/logos-delivery/issues/1288) | bug(waku-discv5): Metric waku_discv5_discovered is not updated correctly | | P2 | 2 | discv5 metric overcounts |
| [#971](https://github.com/logos-messaging/logos-delivery/issues/971) | fix: graceful shutdown when pressing ctrl+c during node setup | | P2 | 2 | Ctrl+C during setup; pairs with #4345 |
| [#3083](https://github.com/logos-messaging/logos-delivery/issues/3083) | chore: add Postgres panels in Status and Waku fleets | | Triage | 2 | Postgres dashboards |
| [#2960](https://github.com/logos-messaging/logos-delivery/issues/2960) | chore: create a separate postgres nim project that combines db_connector and chronos | | Triage | 2 | shared postgres lib; recent activity |
| [#2549](https://github.com/logos-messaging/logos-delivery/issues/2549) | feat: Archive policy triggers update in Waku Sync | stubbsta | Triage | 2 | retention vs sync consistency |
| [#2528](https://github.com/logos-messaging/logos-delivery/issues/2528) | chore: simplify nwaku config items | Ivansete-status | Triage | 2 | config UX |
| [#2465](https://github.com/logos-messaging/logos-delivery/issues/2465) | Support IPv6 | | Triage | 2 | IPv6, parked |
| [#1892](https://github.com/logos-messaging/logos-delivery/issues/1892) | feat: altruistic sharding to ensure shard coverage | | Triage | 2 | shard coverage; network design |
| [#2161](https://github.com/logos-messaging/logos-delivery/issues/2161) | chore: improve the metadata protocol implementation | jm-clius | Stale owner – reassign/close | 2 | metadata protocol friction; stale owner |
| [#4433](https://github.com/logos-messaging/logos-delivery/issues/4433) | question: lightpush v3 client turns the service's BAD_REQUEST for an undecodable request into "response failure, requestId mismatch" | | Triage | 2 | lightpush client hides service BAD_REQUEST as requestId mismatch |
| [#4435](https://github.com/logos-messaging/logos-delivery/issues/4435) | question: filter UNSUBSCRIBE of a criterion the requester does not hold answers 200 or 404 depending on other peers, and its 404 can follow a partial removal | | Triage | 2 | filter unsubscribe status depends on other peers; partial removal |
| [#4438](https://github.com/logos-messaging/logos-delivery/issues/4438) | bug: the archive counts a message it already holds as written on Postgres and as an insert failure on sqlite | | Triage | 2 | duplicate insert counted differently on Postgres vs sqlite (metrics) |
| [#4431](https://github.com/logos-messaging/logos-delivery/issues/4431) | bug: /lightpush/v3/message answers 500 for INVALID_MESSAGE (420), and 413 or 500 for the same oversize message | | Triage | 2 | lightpush REST status mapping (420→500, 413 vs 500) |
| [#3446](https://github.com/logos-messaging/logos-delivery/issues/3446) | chore: simplify shard subscriptions in the codebase | | P2 | 1 | shard subscriptions now centralised |
| [#3222](https://github.com/logos-messaging/logos-delivery/issues/3222) | chore: improve WakuRelay subscribe return value | | P2 | 1 | API nit |
| [#3012](https://github.com/logos-messaging/logos-delivery/issues/3012) | chore: take off filter message push timeouts from message handling metric  | | Triage | 1 | metric noise |
| [#2255](https://github.com/logos-messaging/logos-delivery/issues/2255) | bug: pubsub topic not mandatory for filter/v2/subscriptions  | | Triage | 1 | REST spec mismatch |
| [#2245](https://github.com/logos-messaging/logos-delivery/issues/2245) | bug: incomplete data sent or received log appearing when WSS is enabled | | Triage | 1 | WSS debug log noise |
| [#1363](https://github.com/logos-messaging/logos-delivery/issues/1363) | feat(wakunode2): support configuration via JSON file | | Triage | 1 | TOML + env already; no infra ask since 2022 |
| [#4432](https://github.com/logos-messaging/logos-delivery/issues/4432) | bug: REST API answers an undecodable JSON body without the decoder's reason | | Triage | 1 | REST decode errors lose the reason |
| [#4434](https://github.com/logos-messaging/logos-delivery/issues/4434) | bug: /filter/v2/subscriptions answers 200 "UNKNOWN" without pubsubTopic under static sharding, and its message cache ignores the result | | Triage | 1 | filter REST 200 "UNKNOWN" under static sharding |
| [#4437](https://github.com/logos-messaging/logos-delivery/issues/4437) | question: GET /store/v3/messages reads a startTime or endTime of 0 or less as absent, and a negative pageSize as the maximum | | Triage | 1 | store REST edge values (time ≤0, negative pageSize) |

## Mix integration (3)

| # | Title | Assignee | Priority / action |
|---|---|---|---|
| [#4357](https://github.com/logos-messaging/logos-delivery/issues/4357) | Mix replies can fail for senders behind NAT | fcecin |  |
| [#4352](https://github.com/logos-messaging/logos-delivery/issues/4352) | Mix sends time out on most attempts over lightpush (logos.dev) | fcecin |  |
| [#4356](https://github.com/logos-messaging/logos-delivery/issues/4356) | feat(mix): support native Delivery routing with shared RLN proofs | | P1 |

## Logos modularization (6)

| # | Title | Assignee | Priority / action |
|---|---|---|---|
| [#3883](https://github.com/logos-messaging/logos-delivery/issues/3883) | Expose additional dashboard node info: shards, clusterId, enrtree, mixPubKey, protocols, websocket | igor-sirotin |  |
| [#4328](https://github.com/logos-messaging/logos-delivery/issues/4328) | chore(messaging): `send` should only mint the id, enqueue the task and wake the send loop | fcecin |  |
| [#2456](https://github.com/logos-messaging/logos-delivery/issues/2456) | chore: Support auto sharding and static sharding in libwaku  | | Triage |
| [#2453](https://github.com/logos-messaging/logos-delivery/issues/2453) | chore: confirm that sharding logic is controlled in waku_node modules  | | Triage |
| [#2412](https://github.com/logos-messaging/logos-delivery/issues/2412) | bug(cbindings): support DNS based multiaddresses | | Triage |
| [#1700](https://github.com/logos-messaging/logos-delivery/issues/1700) | feat: Pluggable validator/QoS interface | | Triage |

## RLN (5)

| # | Title | Assignee | Priority / action |
|---|---|---|---|
| [#4300](https://github.com/logos-messaging/logos-delivery/issues/4300) | chore: Improve response handling for rln module requests | | P1 |
| [#4279](https://github.com/logos-messaging/logos-delivery/issues/4279) | chore(rln): bump zerokit to v2.0.3 (mingw nix package) | | P1 |
| [#3846](https://github.com/logos-messaging/logos-delivery/issues/3846) | bug: RLN registration not working with latest docker image | | P2 |
| [#3482](https://github.com/logos-messaging/logos-delivery/issues/3482) | chore: Add functionality for all RLN contract methods | | P2 |
| [#4403](https://github.com/logos-messaging/logos-delivery/issues/4403) | bug: send retries for 60 s instead of failing when the node has no RLN membership | | Triage |

## CI / QA (8)

| # | Title | Assignee | Priority / action |
|---|---|---|---|
| [#1009](https://github.com/logos-messaging/logos-delivery/issues/1009) | arm64 nwaku Docker image | vpavlin | P2 |
| [#2558](https://github.com/logos-messaging/logos-delivery/issues/2558) | chore: add auto setup for test network | | Triage |
| [#1877](https://github.com/logos-messaging/logos-delivery/issues/1877) | chore: build a container image from existing binaries | | Triage |
| [#1876](https://github.com/logos-messaging/logos-delivery/issues/1876) | chore: run update target along with build target | | Triage |
| [#1847](https://github.com/logos-messaging/logos-delivery/issues/1847) | feat: Generate a binary(cross compiled) to run nwaku on a Raspberry Pi | | Triage |
| [#1282](https://github.com/logos-messaging/logos-delivery/issues/1282) | fix: reenable the store resume flaky test cases | | Triage |
| [#896](https://github.com/logos-messaging/logos-delivery/issues/896) | Re-enable CI for Windows environments | | Triage |
| [#4398](https://github.com/logos-messaging/logos-delivery/issues/4398) | ci: further caching improvements | | Triage |
