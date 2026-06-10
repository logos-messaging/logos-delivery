import ../../common/utils/parse_size_units

const
  ## https://rfc.vac.dev/spec/64/#message-size
  DefaultMaxWakuMessageSizeStr* = "150KiB" # Remember that 1 MiB is the PubSub default
  DefaultMaxWakuMessageSize* = parseCorrectMsgSize(DefaultMaxWakuMessageSizeStr)

  DefaultSafetyBufferProtocolOverhead* = 64 * 1024 # overhead measured in bytes
