import results

type ReliableChannelManagerConf* = object
  ## All-`Opt` partial; unset fields fall back to `createReliableChannel` defaults.
  segmentationEnableReedSolomon*: Opt[bool]
    ## Add Reed-Solomon parity segments for recovery of lost segments.
  segmentationSegmentSizeBytes*: Opt[int] ## Maximum segment size in bytes.
  sdsAcknowledgementTimeoutMs*: Opt[int]
    ## Time to wait before retransmitting an unacknowledged message.
  sdsMaxRetransmissions*: Opt[int]
    ## Maximum retransmission attempts before delivery fails.
  sdsCausalHistorySize*: Opt[int] ## Number of message ids kept in causal history.
  rateLimitEnabled*: Opt[bool] ## Enable rate limiting.
  rateLimitEpochPeriodSec*: Opt[int] ## Rate-limit epoch length in seconds.
  rateLimitMessagesPerEpoch*: Opt[int] ## Messages allowed per rate-limit epoch.
