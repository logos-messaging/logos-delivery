import results

type ReliableChannelManagerConf* = object
  ## All-`Opt` partial; unset fields fall back to `createReliableChannel` defaults.
  segmentationSegmentSizeBytes*: Opt[int] ## Maximum segment size in bytes.
  segmentationParityRate*: Opt[float]
    ## Reed-Solomon parity segments as a fraction of the data segments;
    ## 0 disables parity. Must not exceed 1.
  segmentationReconstructionTimeoutSeconds*: Opt[int]
    ## How long a partial segment set may go without a new segment before it is
    ## dropped.
  segmentationCleanupIntervalSeconds*: Opt[int]
    ## How often expired segment sets are swept. Must be positive and no larger
    ## than the reconstruction timeout.
  segmentationMaxTotalSegments*: Opt[int]
    ## Greatest number of segments one payload may be split into, data and
    ## parity together. All participants must agree on this.
  segmentationMaxSegmentSets*: Opt[int]
    ## Concurrent partial segment sets retained; the least recently updated is
    ## evicted first.
  segmentationMaxBufferedBytes*: Opt[int]
    ## Segment bytes held across all incomplete sets. The bound that actually
    ## caps reassembly memory.
  sdsAcknowledgementTimeoutMs*: Opt[int]
    ## Time to wait before retransmitting an unacknowledged message.
  sdsMaxRetransmissions*: Opt[int]
    ## Maximum retransmission attempts before delivery fails.
  sdsCausalHistorySize*: Opt[int] ## Number of message ids kept in causal history.
  rateLimitEnabled*: Opt[bool] ## Enable rate limiting.
  rateLimitEpochPeriodSec*: Opt[int] ## Rate-limit epoch length in seconds.
  rateLimitMessagesPerEpoch*: Opt[int] ## Messages allowed per rate-limit epoch.
