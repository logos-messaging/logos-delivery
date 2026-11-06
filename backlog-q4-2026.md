# logos-delivery — Q4 2026 backlog draft (internal)

Snapshot 2026-09-29 · 200 open issues · every open issue categorized. Order: assigned → P0 → P1 → P2 → Triage → Stale owner → Close.

| Category | Open | Assigned (active) | P0 | P1 | Triage/P2 | Stale | Close |
|---|---|---|---|---|---|---|---|
| Maintenance and code refactor | 135 | 8 | 5 | 15 | 81 | 9 | 18 |
| Mix integration | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Logos modularization | 14 | 4 | 5 | 1 | 4 | 2 | 0 |
| RLN | 28 | 2 | 3 | 5 | 10 | 6 | 2 |
| CI / QA | 23 | 4 | 2 | 0 | 10 | 4 | 3 |

_Assigned issues keep their P-level, so they also count in the P0/P1 columns._

## Maintenance and code refactor

| # | Title | Assignee | Priority / action | Parent |
|---|---|---|---|---|
| [#4252](https://github.com/logos-messaging/logos-delivery/issues/4252) | Prepare release 0.39.0 | Ivansete-status |  | - |
| [#4226](https://github.com/logos-messaging/logos-delivery/issues/4226) | Service discovery spams dial failures to unroutable addresses (127.0.0.1/tcp/0, 0.0.0.0) | NagyZoltanPeter |  | - |
| [#4044](https://github.com/logos-messaging/logos-delivery/issues/4044) | standardize the use of Persistence | NagyZoltanPeter |  | - |
| [#3534](https://github.com/logos-messaging/logos-delivery/issues/3534) | bug: not able to properly cleanup old partitions | Ivansete-status |  | - |
| [#3980](https://github.com/logos-messaging/logos-delivery/issues/3980) | nim-libp2p is deprecating minprotobuf | fcecin |  | logos-delivery#4043 |
| [#3360](https://github.com/logos-messaging/logos-delivery/issues/3360) | chore: enable nwaku log sink to be configurable for stderr and file output. | NagyZoltanPeter |  | logos-delivery#4043 |
| [#4078](https://github.com/logos-messaging/logos-delivery/issues/4078) | MIssing data in some grafana dashboards | igor-sirotin |  | - |
| [#2594](https://github.com/logos-messaging/logos-delivery/issues/2594) | bug: ENR shouldn't be used for pruning | Ivansete-status | Triage | logos-delivery#4043 |
| [#4345](https://github.com/logos-messaging/logos-delivery/issues/4345) | A failed start leaves the node half started |  | P0 | logos-delivery#4043 |
| [#3933](https://github.com/logos-messaging/logos-delivery/issues/3933) | Peer-exchange serves stale ENRs: PeerStore copy is never liveness-pruned |  | P0 | logos-delivery#4043 |
| [#3844](https://github.com/logos-messaging/logos-delivery/issues/3844) | Allow handling peers by stream and protocol instead of pruning the whole connection |  | P0 | logos-delivery#4043 |
| [#4245](https://github.com/logos-messaging/logos-delivery/issues/4245) | chore: align connection management with libp2p and metadata spec |  | P0 | logos-delivery#4043 |
| [#3867](https://github.com/logos-messaging/logos-delivery/issues/3867) | wakucanary fails for boot node in status.prod |  | P0 | logos-delivery#4043 |
| [#4273](https://github.com/logos-messaging/logos-delivery/issues/4273) | Architectural layering concerns |  | P1 | logos-delivery#4043 |
| [#4123](https://github.com/logos-messaging/logos-delivery/issues/4123) | chore(archive): deprecate capacity retention policy |  | P1 | logos-delivery#4043 |
| [#4168](https://github.com/logos-messaging/logos-delivery/issues/4168) | bug: store REST reports the same failure as 500 or as 200 depending on `peerAddr` |  | P1 | logos-delivery#4043 |
| [#4167](https://github.com/logos-messaging/logos-delivery/issues/4167) | chore: store REST `ascending` parameter contradicts its own API spec |  | P1 | logos-delivery#4043 |
| [#4133](https://github.com/logos-messaging/logos-delivery/issues/4133) | chore: Fix dead CLI config field for storeSync |  | P1 | logos-delivery#4043 |
| [#3859](https://github.com/logos-messaging/logos-delivery/issues/3859) | postgres exception no partition of relation "messages" found |  | P1 | logos-delivery#4043 |
| [#3688](https://github.com/logos-messaging/logos-delivery/issues/3688) | bug: store node keeps bothering db to create partition even though it exists already |  | P1 | logos-delivery#4043 |
| [#3575](https://github.com/logos-messaging/logos-delivery/issues/3575) | bug: partitions are not properly removed |  | P1 | logos-delivery#4043 |
| [#3524](https://github.com/logos-messaging/logos-delivery/issues/3524) | bug: GET http://{node}/store/v3/messages endpoint fails (PEER_DIAL_FAILURE) |  | P1 | logos-delivery#4043 |
| [#3579](https://github.com/logos-messaging/logos-delivery/issues/3579) | bug: Align peer-exchange implementation as per spec |  | P1 | logos-delivery#4043 |
| [#3695](https://github.com/logos-messaging/logos-delivery/issues/3695) | bug:  cluster-id overrides custom DISCV5_BOOTSTRAP_ENRS, preventing discovery of custom bootstrap nodes |  | P1 | logos-delivery#4043 |
| [#2998](https://github.com/logos-messaging/logos-delivery/issues/2998) | bug: duplicate messages on the network |  | P1 | logos-delivery#4043 |
| [#3824](https://github.com/logos-messaging/logos-delivery/issues/3824) | deprecate lighpush legacy |  | P1 | logos-delivery#4043 |
| [#4251](https://github.com/logos-messaging/logos-delivery/issues/4251) | docs: add a diagram of component inter-relations in logos-delivery |  | P1 | logos-delivery#4043 |
| [#4043](https://github.com/logos-messaging/logos-delivery/issues/4043) | Maintenance Y2026H2 |  | P1 | pm#479 |
| [#3677](https://github.com/logos-messaging/logos-delivery/issues/3677) | bug: attempting to call undeclared routine: 'exitNode' |  | P2 | - |
| [#3635](https://github.com/logos-messaging/logos-delivery/issues/3635) | bug: [Test/Feedback] nwaku v0.36.0: RLN Success, Bandwidth Stable, BUT Lightpush Dial Failure on High Payload |  | P2 | - |
| [#3476](https://github.com/logos-messaging/logos-delivery/issues/3476) | chore: optimize keep alive |  | P2 | - |
| [#3462](https://github.com/logos-messaging/logos-delivery/issues/3462) | chore: store RFC - code missmatched |  | P2 | - |
| [#3446](https://github.com/logos-messaging/logos-delivery/issues/3446) | chore: simplify shard subscriptions in the codebase |  | P2 | - |
| [#3439](https://github.com/logos-messaging/logos-delivery/issues/3439) | chore: make the switch private in the Peer Manager |  | P2 | - |
| [#3339](https://github.com/logos-messaging/logos-delivery/issues/3339) | chore: refactor peer-exchange and isolate client and server functionalities |  | P2 | - |
| [#3335](https://github.com/logos-messaging/logos-delivery/issues/3335) | bug: lightpush only uses relay |  | P2 | - |
| [#3250](https://github.com/logos-messaging/logos-delivery/issues/3250) | bug: Fail to start when passing a high number of shards |  | P2 | - |
| [#3245](https://github.com/logos-messaging/logos-delivery/issues/3245) | bug: waku_total_unique_peers metric wrong value |  | P2 | - |
| [#3231](https://github.com/logos-messaging/logos-delivery/issues/3231) | bug: possible issue where-in filter push fails to a lightclient on ip address change of the client |  | P2 | - |
| [#3222](https://github.com/logos-messaging/logos-delivery/issues/3222) | chore: improve WakuRelay subscribe return value |  | P2 | - |
| [#3169](https://github.com/logos-messaging/logos-delivery/issues/3169) | bug: Filter request ID isn't unique |  | P2 | - |
| [#3165](https://github.com/logos-messaging/logos-delivery/issues/3165) | bug: inconsistency in contentTopic generation |  | P2 | - |
| [#3135](https://github.com/logos-messaging/logos-delivery/issues/3135) | chore:lack of info for REST APIs |  | Triage | - |
| [#3128](https://github.com/logos-messaging/logos-delivery/issues/3128) | chore:pubsub topic && content_topic encoding is optional |  | Triage | - |
| [#3083](https://github.com/logos-messaging/logos-delivery/issues/3083) | chore: add Postgres panels in Status and Waku fleets |  | Triage | - |
| [#3043](https://github.com/logos-messaging/logos-delivery/issues/3043) | bug: big dependency with waku.sandbox nodes for a node to joing The Waku Network |  | Triage | - |
| [#3018](https://github.com/logos-messaging/logos-delivery/issues/3018) | bug: Node setup complete even --store-message-db-url is wrong |  | Triage | - |
| [#3012](https://github.com/logos-messaging/logos-delivery/issues/3012) | chore: take off filter message push timeouts from message handling metric  |  | Triage | - |
| [#3000](https://github.com/logos-messaging/logos-delivery/issues/3000) | chore: clarify internal message flow |  | Triage | - |
| [#2990](https://github.com/logos-messaging/logos-delivery/issues/2990) | bug: waku_archive_insert_duration_seconds metric should have value |  | Triage | - |
| [#2961](https://github.com/logos-messaging/logos-delivery/issues/2961) | chore: determine why so many opened TCP sockets in nwaku |  | Triage | - |
| [#2960](https://github.com/logos-messaging/logos-delivery/issues/2960) | chore: create a separate postgres nim project that combines db_connector and chronos |  | Triage | - |
| [#2901](https://github.com/logos-messaging/logos-delivery/issues/2901) | bug: (most) waku node metrics weird initial value |  | Triage | - |
| [#2798](https://github.com/logos-messaging/logos-delivery/issues/2798) | feat: configurable peer persistence DB path |  | Triage | - |
| [#2774](https://github.com/logos-messaging/logos-delivery/issues/2774) | chore: update lightpush client API |  | Triage | - |
| [#2704](https://github.com/logos-messaging/logos-delivery/issues/2704) | chore: prevent ingesting duplicate messages into Waku Sync |  | Triage | - |
| [#2599](https://github.com/logos-messaging/logos-delivery/issues/2599) | chore: automatically add OPTIONS method to REST API |  | Triage | - |
| [#2549](https://github.com/logos-messaging/logos-delivery/issues/2549) | feat: Archive policy triggers update in Waku Sync |  | Triage | - |
| [#2528](https://github.com/logos-messaging/logos-delivery/issues/2528) | chore: simplify nwaku config items |  | Triage | - |
| [#2465](https://github.com/logos-messaging/logos-delivery/issues/2465) | Support IPv6 |  | Triage | - |
| [#2437](https://github.com/logos-messaging/logos-delivery/issues/2437) | bug: relay publish fails with 400 Bad Request when message contains an unknown field |  | Triage | - |
| [#2407](https://github.com/logos-messaging/logos-delivery/issues/2407) | feat: Static configuration for each cluster-id |  | Triage | - |
| [#2405](https://github.com/logos-messaging/logos-delivery/issues/2405) | chore: return error in REST when trying to publish message without peers in topic |  | Triage | - |
| [#2386](https://github.com/logos-messaging/logos-delivery/issues/2386) | feat: provide a flag to disable flood-publish |  | Triage | - |
| [#2358](https://github.com/logos-messaging/logos-delivery/issues/2358) | chore: remove PUT /filter/v2/subscriptions |  | Triage | - |
| [#2326](https://github.com/logos-messaging/logos-delivery/issues/2326) | chore: reduce log level or logs from particular files |  | Triage | - |
| [#2322](https://github.com/logos-messaging/logos-delivery/issues/2322) | chore: make parameterizible cache size |  | Triage | - |
| [#2275](https://github.com/logos-messaging/logos-delivery/issues/2275) | chore: fixing the MB/MiB based unit values in size based retention policy. |  | Triage | - |
| [#2270](https://github.com/logos-messaging/logos-delivery/issues/2270) | chore: improve node initialization sequence to make it more operator friendly |  | Triage | - |
| [#2268](https://github.com/logos-messaging/logos-delivery/issues/2268) | bug: segmentation fault in status.test fleet |  | Triage | - |
| [#2264](https://github.com/logos-messaging/logos-delivery/issues/2264) | chore: log the full peerIds |  | Triage | - |
| [#2258](https://github.com/logos-messaging/logos-delivery/issues/2258) | chore: make autosharding configurable |  | Triage | - |
| [#2256](https://github.com/logos-messaging/logos-delivery/issues/2256) | chore: support enabling debug logging in specific modules |  | Triage | - |
| [#2255](https://github.com/logos-messaging/logos-delivery/issues/2255) | bug: pubsub topic not mandatory for filter/v2/subscriptions  |  | Triage | - |
| [#2245](https://github.com/logos-messaging/logos-delivery/issues/2245) | bug: incomplete data sent or received log appearing when WSS is enabled |  | Triage | - |
| [#2181](https://github.com/logos-messaging/logos-delivery/issues/2181) | chore: specify that the WebSocket key format needs to be PKCS#8 |  | Triage | - |
| [#2156](https://github.com/logos-messaging/logos-delivery/issues/2156) | chore: sqlite vacuum tmpdir space issue documentation and logging |  | Triage | - |
| [#2146](https://github.com/logos-messaging/logos-delivery/issues/2146) | bug: Relay and filter max message size |  | Triage | - |
| [#2136](https://github.com/logos-messaging/logos-delivery/issues/2136) | chore: wakunode2: allow filter and lightpush clients without pre-specify service node |  | Triage | - |
| [#2103](https://github.com/logos-messaging/logos-delivery/issues/2103) | wakucanary: support of other protocols |  | Triage | - |
| [#1959](https://github.com/logos-messaging/logos-delivery/issues/1959) | chore: Change relay push message RestApi signature by moving pubsubTopic argument to the body. |  | Triage | - |
| [#1947](https://github.com/logos-messaging/logos-delivery/issues/1947) | feat: Dynamic subscribe/unsubscribe mechanism (or similar) |  | Triage | - |
| [#1929](https://github.com/logos-messaging/logos-delivery/issues/1929) | [Epic] Operator experience: providing services using nwaku |  | Triage | - |
| [#1892](https://github.com/logos-messaging/logos-delivery/issues/1892) | feat: altruistic sharding to ensure shard coverage |  | Triage | - |
| [#1824](https://github.com/logos-messaging/logos-delivery/issues/1824) | feat: archive retention policy task timer config |  | Triage | - |
| [#1757](https://github.com/logos-messaging/logos-delivery/issues/1757) | feat: implement token bucket-controlled limit for inbound connections |  | Triage | - |
| [#1699](https://github.com/logos-messaging/logos-delivery/issues/1699) | bug: node does not fails and continues with a wrongly configured wss |  | Triage | - |
| [#1652](https://github.com/logos-messaging/logos-delivery/issues/1652) | chore: put each "namespaced" group of REST API endpoints behind a conf flag |  | Triage | - |
| [#1593](https://github.com/logos-messaging/logos-delivery/issues/1593) | feat: allow providing node key using a file |  | Triage | - |
| [#1558](https://github.com/logos-messaging/logos-delivery/issues/1558) | chore: match CLI argument and environment variable serialization |  | Triage | - |
| [#1549](https://github.com/logos-messaging/logos-delivery/issues/1549) | bug: Duplicated peers in get_waku_v2_admin_v1_peers |  | Triage | - |
| [#1542](https://github.com/logos-messaging/logos-delivery/issues/1542) | bug: messages being gossiped one hour later |  | Triage | - |
| [#1506](https://github.com/logos-messaging/logos-delivery/issues/1506) | feat request: add store query request duration metric |  | Triage | - |
| [#1492](https://github.com/logos-messaging/logos-delivery/issues/1492) | bug: `MULTIADDR_ENR_FIELD` is not read when extracting dialable peer info from enr record |  | Triage | - |
| [#1490](https://github.com/logos-messaging/logos-delivery/issues/1490) | Get rid of the Hardcoded DNS server addresses |  | Triage | - |
| [#1485](https://github.com/logos-messaging/logos-delivery/issues/1485) | bug: mplex error upon reconnection |  | Triage | - |
| [#1391](https://github.com/logos-messaging/logos-delivery/issues/1391) | bug: SIGSEGV: Illegal storage access |  | Triage | - |
| [#1354](https://github.com/logos-messaging/logos-delivery/issues/1354) | feat(disc): add discover mechanisms metrics |  | Triage | - |
| [#1312](https://github.com/logos-messaging/logos-delivery/issues/1312) | chore: improve error handling |  | Triage | - |
| [#1288](https://github.com/logos-messaging/logos-delivery/issues/1288) | bug(waku-discv5): Metric waku_discv5_discovered is not updated correctly |  | Triage | - |
| [#1184](https://github.com/logos-messaging/logos-delivery/issues/1184) | UPnP doesn't open port for WS / WSS |  | Triage | - |
| [#1160](https://github.com/logos-messaging/logos-delivery/issues/1160) | chore: better performance-oriented metrics |  | Triage | - |
| [#1137](https://github.com/logos-messaging/logos-delivery/issues/1137) | feat: Support multiple DNS discovery trees |  | Triage | - |
| [#1003](https://github.com/logos-messaging/logos-delivery/issues/1003) | Laundry list: `nwaku` operator guide improvements |  | Triage | - |
| [#971](https://github.com/logos-messaging/logos-delivery/issues/971) | fix: graceful shutdown when pressing ctrl+c during node setup |  | Triage | - |
| [#959](https://github.com/logos-messaging/logos-delivery/issues/959) | wakunode2 cannot be restarted immediately after stopping |  | Triage | - |
| [#939](https://github.com/logos-messaging/logos-delivery/issues/939) | Mitigate under/over-flows in timestamp arithmetic |  | Triage | - |
| [#872](https://github.com/logos-messaging/logos-delivery/issues/872) | Add WebRTC Direct Transport |  | Triage | - |
| [#3062](https://github.com/logos-messaging/logos-delivery/issues/3062) | bug: metadata protocol is not being configured with shards resolved from `--content-topic` CLI flag | gabrielmer | Stale owner – reassign/close | - |
| [#3034](https://github.com/logos-messaging/logos-delivery/issues/3034) | chore: make the msg hash time-sortable | gabrielmer | Stale owner – reassign/close | - |
| [#2792](https://github.com/logos-messaging/logos-delivery/issues/2792) | bug: failed to store peers to persistent storage | SionoiS | Stale owner – reassign/close | - |
| [#2790](https://github.com/logos-messaging/logos-delivery/issues/2790) | chore(store): completely remove Store v2 | SionoiS | Stale owner – reassign/close | - |
| [#2538](https://github.com/logos-messaging/logos-delivery/issues/2538) | bug: autosharding resolves content topics to wrong shard | alrevuelta | Stale owner – reassign/close | - |
| [#2173](https://github.com/logos-messaging/logos-delivery/issues/2173) | bug: wakunode2 systemd unit restarts about 10-15x per day | vpavlin | Stale owner – reassign/close | - |
| [#2161](https://github.com/logos-messaging/logos-delivery/issues/2161) | chore: improve the metadata protocol implementation | jm-clius | Stale owner – reassign/close | - |
| [#1937](https://github.com/logos-messaging/logos-delivery/issues/1937) | feat: Autosharding protocol changes for req-resp protocols | SionoiS | Stale owner – reassign/close | - |
| [#986](https://github.com/logos-messaging/logos-delivery/issues/986) | Heap analysis using `heaptracker` | gabrielmer | Stale owner – reassign/close | - |
| [#3101](https://github.com/logos-messaging/logos-delivery/issues/3101) | chore: adapt Postgres for horizontal scale |  | Close: parent epic ld#3098 closed | logos-delivery#3098 |
| [#3100](https://github.com/logos-messaging/logos-delivery/issues/3100) | chore: review possible optimization with https://pganalyze.com/ |  | Close: parent epic ld#3098 closed | logos-delivery#3098 |
| [#3099](https://github.com/logos-messaging/logos-delivery/issues/3099) | chore: add Redis on the top of Postgres |  | Close: parent epic ld#3098 closed | logos-delivery#3098 |
| [#2359](https://github.com/logos-messaging/logos-delivery/issues/2359) | feat: allow port 0 configuration on Waku node object |  | Close: done – port 0 verified (see #3268) | - |
| [#2247](https://github.com/logos-messaging/logos-delivery/issues/2247) | chore: verify size calculation MiB != MB |  | Close: dup of #2275 | - |
| [#2130](https://github.com/logos-messaging/logos-delivery/issues/2130) | feat: enable circuit-relay client |  | Close: parent ld#3076 closed | logos-delivery#3076 |
| [#1752](https://github.com/logos-messaging/logos-delivery/issues/1752) | feat: support IPv6 connectivity |  | Close: dup of #2465 | - |
| [#1363](https://github.com/logos-messaging/logos-delivery/issues/1363) | feat(wakunode2): support configuration via JSON file  |  | Close: wakunode2 – obsolete | - |
| [#1361](https://github.com/logos-messaging/logos-delivery/issues/1361) | feat: move protocol wire format codecs to nim-protobuf-serialization |  | Close: dup of #3980 | - |
| [#1251](https://github.com/logos-messaging/logos-delivery/issues/1251) | feat(chat2): peers  |  | Close: chat2 – obsolete | - |
| [#1214](https://github.com/logos-messaging/logos-delivery/issues/1214) | feat: support `RateLimitProof` and `Ephemeral` attributes in wakunode2 JSON-RPC/REST APIs |  | Close: JSON-RPC removed | - |
| [#1115](https://github.com/logos-messaging/logos-delivery/issues/1115) | chore: Adding an ASCII  loading indicator when chat2 setup is in progress |  | Close: chat2 – obsolete | - |
| [#1066](https://github.com/logos-messaging/logos-delivery/issues/1066) | [Epic] add support to multi-devices communications |  | Close: Noise – obsolete | - |
| [#1064](https://github.com/logos-messaging/logos-delivery/issues/1064) | [Epic] complete/update Noise module implementation |  | Close: Noise – obsolete | - |
| [#1052](https://github.com/logos-messaging/logos-delivery/issues/1052) | Track: Conversational-security - Implementing Noise Sessions |  | Close: Noise – obsolete | - |
| [#1002](https://github.com/logos-messaging/logos-delivery/issues/1002) | `nwaku` binaries name change |  | Close: nwaku naming – obsolete | - |
| [#942](https://github.com/logos-messaging/logos-delivery/issues/942) | Enhancement/fixup: define encode/decode interfaces for all Waku payload versions |  | Close: Noise – obsolete | - |
| [#881](https://github.com/logos-messaging/logos-delivery/issues/881) | Integrating Noise protocols in Waku2 |  | Close: Noise – obsolete | - |

## Mix integration

_No open issues. Pending mix work lives in open PRs #3931 (DoS protection) and #3807 (cover traffic), chaitanyaprem, idle since 2026-09-09._

## Logos modularization

| # | Title | Assignee | Priority / action | Parent |
|---|---|---|---|---|
| [#3883](https://github.com/logos-messaging/logos-delivery/issues/3883) | Expose additional dashboard node info: shards, clusterId, enrtree, mixPubKey, protocols, websocket | igor-sirotin |  | - |
| [#4328](https://github.com/logos-messaging/logos-delivery/issues/4328) | chore(messaging): `send` should only mint the id, enqueue the task and wake the send loop | fcecin |  | - |
| [#4278](https://github.com/logos-messaging/logos-delivery/issues/4278) | Do not backfill history for newly subscribed content topics | fcecin | P0 | pm#481 |
| [#4341](https://github.com/logos-messaging/logos-delivery/issues/4341) | Allow pluggable nim-libp2p | Ivansete-status | P1 | pm#479 |
| [#3907](https://github.com/logos-messaging/logos-delivery/issues/3907) | Messaging API additions required by Status (version field, store-peer selection, retry, priority, node-info, connectivity hint) |  | P0 | pm#380 |
| [#4087](https://github.com/logos-messaging/logos-delivery/issues/4087) | bug: messaging api and reliable channel api share kernel state without ownership |  | P0 | - |
| [#4305](https://github.com/logos-messaging/logos-delivery/issues/4305) | feat(channels): support ephemeral messages in the Reliable Channel API |  | P0 | pm#483 |
| [#4121](https://github.com/logos-messaging/logos-delivery/issues/4121) | FFI C bindings are never generated: genBindings() writes nothing without --experimental:vmopsDanger |  | P0 | - |
| [#2456](https://github.com/logos-messaging/logos-delivery/issues/2456) | chore: Support auto sharding and static sharding in libwaku  |  | Triage | - |
| [#2453](https://github.com/logos-messaging/logos-delivery/issues/2453) | chore: confirm that sharding logic is controlled in waku_node modules  |  | Triage | - |
| [#2412](https://github.com/logos-messaging/logos-delivery/issues/2412) | bug(cbindings): support DNS based multiaddresses |  | Triage | - |
| [#1700](https://github.com/logos-messaging/logos-delivery/issues/1700) | feat: Pluggable validator/QoS interface |  | Triage | - |
| [#3295](https://github.com/logos-messaging/logos-delivery/issues/3295) | chore: improve libwaku support for concurrent requests | gabrielmer | Stale owner – reassign/close | - |
| [#3246](https://github.com/logos-messaging/logos-delivery/issues/3246) | chore: harden subscribe procs in libwaku | gabrielmer | Stale owner – reassign/close | - |

## RLN

| # | Title | Assignee | Priority / action | Parent |
|---|---|---|---|---|
| [#3838](https://github.com/logos-messaging/logos-delivery/issues/3838) | Allow initialize rate limit manager | stubbsta |  | logos-delivery#4031 |
| [#3846](https://github.com/logos-messaging/logos-delivery/issues/3846) | bug: RLN registration not working with latest docker image | darshankabariya |  | - |
| [#4088](https://github.com/logos-messaging/logos-delivery/issues/4088) | Rewire RLN implementations to use the same RLN interface |  | P0 | pm#416 |
| [#4031](https://github.com/logos-messaging/logos-delivery/issues/4031) | Implement Rate limit manager |  | P0 | pm#432 |
| [#3821](https://github.com/logos-messaging/logos-delivery/issues/3821) | bug: Rln Relay state does not reflect the reality |  | P0 | - |
| [#4300](https://github.com/logos-messaging/logos-delivery/issues/4300) | chore: Improve response handling for rln module requests |  | P1 | - |
| [#4279](https://github.com/logos-messaging/logos-delivery/issues/4279) | chore(rln): bump zerokit to v2.0.3 (mingw nix package) |  | P1 | - |
| [#3531](https://github.com/logos-messaging/logos-delivery/issues/3531) | bug: Lightpush returns misleading 420 client error when server has outdated RLN membership |  | P1 | - |
| [#2928](https://github.com/logos-messaging/logos-delivery/issues/2928) | bug: RLN inconsistent state rejects valid messages |  | P1 | - |
| [#2879](https://github.com/logos-messaging/logos-delivery/issues/2879) | bug: Valid messages identified as spam when other nodes are registering memberships |  | P1 | - |
| [#3482](https://github.com/logos-messaging/logos-delivery/issues/3482) | chore: Add functionality for all RLN contract methods |  | P2 | - |
| [#3075](https://github.com/logos-messaging/logos-delivery/issues/3075) | [Epic: nwaku] Maturing RLN variables/parameters revision |  | Triage | - |
| [#2922](https://github.com/logos-messaging/logos-delivery/issues/2922) | chore: enhance feedback when incorrect RLN parameters are passed |  | Triage | - |
| [#2764](https://github.com/logos-messaging/logos-delivery/issues/2764) | bug: [RLN] member not found in contract after successful registration |  | Triage | - |
| [#2763](https://github.com/logos-messaging/logos-delivery/issues/2763) | bug: RLN flags issues |  | Triage | - |
| [#2762](https://github.com/logos-messaging/logos-delivery/issues/2762) | feat: Improve RLN developer experience |  | Triage | - |
| [#2391](https://github.com/logos-messaging/logos-delivery/issues/2391) | bug: RLN metrics updated in REST handler |  | Triage | - |
| [#2033](https://github.com/logos-messaging/logos-delivery/issues/2033) | feat: c-bindings RLN support |  | Triage | - |
| [#1985](https://github.com/logos-messaging/logos-delivery/issues/1985) | feat: Allow to configure RLN via the REST API |  | Triage | - |
| [#1305](https://github.com/logos-messaging/logos-delivery/issues/1305) | chore(docs): Add waku-rln-relay dashboard usage instructions |  | Triage | - |
| [#2946](https://github.com/logos-messaging/logos-delivery/issues/2946) | bug: RLNv2 rate limit imposed sooner than expected | gabrielmer | Stale owner – reassign/close | - |
| [#2870](https://github.com/logos-messaging/logos-delivery/issues/2870) | bug: invalid RLN messages when other nodes are registering memberships | rymnc | Stale owner – reassign/close | - |
| [#2743](https://github.com/logos-messaging/logos-delivery/issues/2743) | possible bug: [RLN] Unregistered contract test doesn't get web3 provider response | rymnc | Stale owner – reassign/close | - |
| [#2742](https://github.com/logos-messaging/logos-delivery/issues/2742) | possible bug: [RLN] Mebership Index don't need to match | rymnc | Stale owner – reassign/close | - |
| [#1930](https://github.com/logos-messaging/logos-delivery/issues/1930) | chore(rln_keystore_generator): accept only strong passwords  | rymnc | Stale owner – reassign/close | - |
| [#1245](https://github.com/logos-messaging/logos-delivery/issues/1245) | chore(rln-relay): tighten error results with enums | rymnc | Stale owner – reassign/close | - |
| [#2935](https://github.com/logos-messaging/logos-delivery/issues/2935) | feat: investigate stable Layer 2 to deploy RLN |  | Close: RLN L2 chosen | - |
| [#1449](https://github.com/logos-messaging/logos-delivery/issues/1449) | chore(rln-relay): Allow running chat2/wakunode2 with a set of credentials |  | Close: chat2 – obsolete | - |

## CI / QA

| # | Title | Assignee | Priority / action | Parent |
|---|---|---|---|---|
| [#4304](https://github.com/logos-messaging/logos-delivery/issues/4304) | test enhancements | rlve |  | - |
| [#4259](https://github.com/logos-messaging/logos-delivery/issues/4259) | Speed up tests by only running the impacted code | rlve |  | - |
| [#3911](https://github.com/logos-messaging/logos-delivery/issues/3911) | chore: Update build_windows script for nimble | stubbsta |  | logos-delivery#4043 |
| [#3473](https://github.com/logos-messaging/logos-delivery/issues/3473) | bug: (test) cannot compile relay tests | NagyZoltanPeter |  | - |
| [#4342](https://github.com/logos-messaging/logos-delivery/issues/4342) | Speed up PR ci |  | P0 | pm#479 |
| [#4280](https://github.com/logos-messaging/logos-delivery/issues/4280) | bug: flaky "sync 2 nodes 100K msgs 1 diff" — the sync window moves between ingress and reconciliation |  | P0 | - |
| [#3374](https://github.com/logos-messaging/logos-delivery/issues/3374) | tests: Address already in use |  | P2 | - |
| [#2558](https://github.com/logos-messaging/logos-delivery/issues/2558) | chore: add auto setup for test network |  | Triage | - |
| [#2330](https://github.com/logos-messaging/logos-delivery/issues/2330) | chore: Improve testing variations |  | Triage | - |
| [#1877](https://github.com/logos-messaging/logos-delivery/issues/1877) | chore: build a container image from existing binaries |  | Triage | - |
| [#1876](https://github.com/logos-messaging/logos-delivery/issues/1876) | chore: run update target along with build target |  | Triage | - |
| [#1847](https://github.com/logos-messaging/logos-delivery/issues/1847) | feat: Generate a binary(cross compiled) to run nwaku on a Raspberry Pi |  | Triage | - |
| [#1498](https://github.com/logos-messaging/logos-delivery/issues/1498) | feat: include networkmonitor in nwaku docker image |  | Triage | - |
| [#1398](https://github.com/logos-messaging/logos-delivery/issues/1398) | chore: unused import warning in tests |  | Triage | - |
| [#1282](https://github.com/logos-messaging/logos-delivery/issues/1282) | fix: reenable the store resume flaky test cases |  | Triage | - |
| [#896](https://github.com/logos-messaging/logos-delivery/issues/896) | Re-enable CI for Windows environments |  | Triage | - |
| [#3119](https://github.com/logos-messaging/logos-delivery/issues/3119) | chore: testing nwaku's DNS discovery in status-go against fake DNS server | gabrielmer | Stale owner – reassign/close | - |
| [#1879](https://github.com/logos-messaging/logos-delivery/issues/1879) | chore: provide binaries for additional architectures and platforms  | vpavlin | Stale owner – reassign/close | - |
| [#1377](https://github.com/logos-messaging/logos-delivery/issues/1377) | bug(tests): Renaming protocols can't be done + protocolMatcher untested | alrevuelta | Stale owner – reassign/close | - |
| [#1009](https://github.com/logos-messaging/logos-delivery/issues/1009) | arm64 nwaku Docker image | vpavlin | Stale owner – reassign/close | - |
| [#2265](https://github.com/logos-messaging/logos-delivery/issues/2265) | bug: testing peer manager using 0.0.0.0 and port 0 unexpected behavior |  | Close: likely fixed by port-0 work | - |
| [#1789](https://github.com/logos-messaging/logos-delivery/issues/1789) | feat: run some nodes on latest nim-libp2p-auto-bump-unstable branch |  | Close: obsolete | - |
| [#1252](https://github.com/logos-messaging/logos-delivery/issues/1252) | feat(ci) build chat2 and attach to PR |  | Close: chat2 – obsolete | - |
