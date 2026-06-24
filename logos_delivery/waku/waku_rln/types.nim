{.push raises: [].}

import std/tables, chronos, results
import brokers/broker_context

import ./group_manager, ./nonce_manager, ./protocol_types

import logos_delivery/waku/common/error_handling

type WakuRln* = ref object of RootObj
  # the log of nullifiers and Shamir shares of the past messages grouped per epoch
  nullifierLog*: OrderedTable[Epoch, Table[Nullifier, ProofMetadata]]
  lastEpoch*: Epoch # the epoch of the last published rln message
  rlnEpochSizeSec*: uint64
  rlnMaxTimestampGap*: uint64
  rlnMaxEpochGap*: uint64
  groupManager*: GroupManager
  onFatalErrorAction*: OnFatalErrorHandler
  nonceManager*: NonceManager
  epochMonitorFuture*: Future[void]
  rootChangesFuture*: Future[Result[void, string]]
  brokerCtx*: BrokerContext
