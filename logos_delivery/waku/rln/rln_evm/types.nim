{.push raises: [].}

import std/tables, chronos, results, brokers/broker_context

import ./group_manager_base, ./nonce_manager, ./protocol_types

import
  logos_delivery/waku/common/error_handling, logos_delivery/waku/persistency/persistency

type RlnEvm* = ref object of RootObj
  # the log of nullifiers and Shamir shares of the past messages grouped per epoch
  nullifierLog*: OrderedTable[Epoch, Table[Nullifier, ProofMetadata]]
  lastEpoch*: Epoch # the epoch of the last published rln message
  rlnEpochSizeSec*: uint64
  rlnMaxTimestampGap*: uint64
  rlnMaxEpochGap*: uint64
  groupManager*: RlnEvmGroupManagerBase
  onFatalErrorAction*: OnFatalErrorHandler
  nonceManager*: NonceManager
  brokerCtx*: Opt[BrokerContext]
    ## The node's context, through which the backend reaches node services
    ## such as its persistency.
  idStore*: persistency.Job
    ## The node's `rln` persistency job, holding this identity's message id
    ## row. Nil until the first draw or quota read loads it
    ## (`ensureIdsLoaded`).
  idStoreKey*: Key ## This identity's row key in `idStore`.
  refusedUntil*: uint64
    ## Set when the loaded row's epoch is ahead of the clock: the quota
    ## reports no budget for earlier epochs until the clock reaches it.
  reserveLock*: AsyncLock
    ## Held while a message id is drawn and its count saved
    ## (`reserveDurably`), so saves land in the order the ids were drawn.
  epochMonitorFuture*: Future[void]
  rootChangesFuture*: Future[Result[void, string]]
