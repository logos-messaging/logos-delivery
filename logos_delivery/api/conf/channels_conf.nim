import std/options

type ReliableChannelManagerConf* = object
  ## All-`Option` partial; unset fields fall back to `createReliableChannel` defaults.
  segmentationEnableReedSolomon*: Option[bool]
    ## Add Reed-Solomon parity segments for recovery of lost segments.
  segmentationSegmentSizeBytes*: Option[int] ## Maximum segment size in bytes.
  sdsAcknowledgementTimeoutMs*: Option[int]
    ## Time to wait before retransmitting an unacknowledged message.
  sdsMaxRetransmissions*: Option[int]
    ## Maximum retransmission attempts before delivery fails.
  sdsCausalHistorySize*: Option[int] ## Number of message ids kept in causal history.
  rateLimitEnabled*: Option[bool] ## Enable rate limiting.
  rateLimitEpochPeriodSec*: Option[int] ## Rate-limit epoch length in seconds.
  rateLimitMessagesPerEpoch*: Option[int] ## Messages allowed per rate-limit epoch.
