# Component diagrams (Mermaid sources for Miro)

## 1. master (`logos_delivery/waku/`)

```mermaid
flowchart TB
  subgraph Facade["logos_delivery (facade, LogosDelivery.new)"]
    API["api/ (conf, events, types, *_api concepts)"]
  end
  subgraph Top["Upper layers"]
    CH["channels/ ReliableChannelManager, SDS, segmentation, encryption"]
    MSG["messaging/ MessagingClient, delivery_service, rate_limit_manager, rest_api"]
  end
  subgraph Waku["waku/ (kernel)"]
    WAPI["waku/api (relay, publish, peer_manager, events)"]
    FAC["factory (builder, conf_builder, node_factory, waku_conf)"]
    subgraph Node["node/"]
      WN["waku_node (+ waku_node/ relay, filter, lightpush, store, px)"]
      PM["peer_manager + waku_peer_store"]
      SM["subscription_manager, edge_filter_sub_state, shard_subscription"]
      HM["health_monitor"]
    end
    subgraph Proto["Protocols"]
      RELAY["waku_relay"]
      FILT["waku_filter_v2"]
      LP["waku_lightpush (+legacy)"]
      STORE["waku_store / waku_store_sync"]
      PX["waku_peer_exchange"]
      META["waku_metadata"]
      MIX["waku_mix"]
      RDV["waku_rendezvous"]
    end
    ARCH["waku_archive (drivers, retention)"]
    DISC["discovery (discv5, dns)"]
    RLN["rln / waku_keystore"]
    CORE["waku_core, waku_enr, common, requests, utils, net"]
    PERS["persistency"]
    INC["incentivization"]
    subgraph Backend["libp2p_iface + libp2p_backend"]
      IFACE["IHost / IPubSub / IStream"]
      BE["GossipSub, Switch, module adapters"]
    end
  end
  LIBP2P[("nim-libp2p")]
  Facade --> CH --> MSG --> WAPI
  MSG --> WAPI
  WAPI --> WN
  FAC --> WN
  WN --> PM & SM & HM & Proto & ARCH & DISC & RLN
  Proto --> PM
  PM --> RELAY & META
  RELAY --> RLN
  STORE --> ARCH
  Proto --> CORE
  Proto --> IFACE --> BE --> LIBP2P
  PM --> BE
  CH -.-> PERS
  Waku -. "imports api/events, api/types (cycle by folder)" .-> API
```

## 2. refactor/kernel-single-file (`logos_delivery/kernel/`)

```mermaid
flowchart TB
  subgraph Facade["logos_delivery (facade)"]
    API["api/ (conf, types, *_api concepts)"]
  end
  CH["channels/"] --> MSG["messaging/"]
  MSG --> KAPI
  Facade --> CH
  subgraph K["kernel/ (acyclic folder graph)"]
    KAPI["api/ (builder, lifecycle, relay, publish, filter, lightpush, store, peer_manager, health, ...)"]
    CFG["config/ (conf_builder, WakuConf)"]
    EV["events/"]
    SUB["subscription_manager"]
    HMON["health_monitor/"]
    PMG["peer_manager/ (peer_manager, peer_store, online_monitor)"]
    subgraph PR["protocols/"]
      R["relay"] --- F["filter"] --- L["lightpush (+legacy)"]
      S["store / store_sync"] --- X["peer_exchange"] --- M["metadata"] --- MX["mix"] --- RV["rendezvous"]
    end
    ARCH["archive/ (driver, retention_policy)"]
    DISC["discovery/ (+plugin)"]
    RLN["rln/ (keystore, rln_evm, rln_lez)"]
    NET["net/"]
    PERS["persistency/"]
    BASE["base/ (message, topics, enr, health, rate_limit, databases, codecs, ...)"]
  end
  BEND["libp2p_iface + libp2p_backend"] --> LIBP2P[("nim-libp2p")]
  KAPI --> CFG & SUB & HMON & PMG & PR & DISC & EV
  SUB --> EV
  PR --> PMG & BASE
  S --> ARCH
  R --> RLN
  PMG --> BASE
  ARCH --> BASE
  DISC --> BASE
  PR --> BEND
  PMG --> BEND
```

Differences vs master: `waku/` renamed `kernel/` with `waku_` prefixes dropped, `node/` + `factory/` folded into `api/` and `config/`, `common/core/enr/utils/requests` merged into `base/`, protocols grouped under `protocols/`, events moved down, folder import graph made acyclic (addresses #4273 concerns 1 and 5).
