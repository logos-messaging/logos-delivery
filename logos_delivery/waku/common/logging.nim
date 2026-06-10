## This code has been copied and addapted from `status-im/nimbu-eth2` project.
## Link: https://github.com/status-im/nimbus-eth2/blob/c585b0a5b1ae4d55af38ad7f4715ad455e791552/beacon_chain/nimbus_binary_common.nim
import
  std/[typetraits, os, strutils, syncio],
  chronicles,
  chronicles/log_output,
  chronicles/topics_registry

export chronicles.LogLevel

{.push raises: [].}

type LogFormat* = enum
  TEXT
  JSON

## Utils

proc stripAnsi(v: string): string =
  ## Copied from: https://github.com/status-im/nimbus-eth2/blob/stable/beacon_chain/nimbus_binary_common.nim#L41
  ## Silly chronicles, colors is a compile-time property
  var
    res = newStringOfCap(v.len)
    i: int

  while i < v.len:
    let c = v[i]
    if c == '\x1b':
      var
        x = i + 1
        found = false

      while x < v.len: # look for [..m
        let c2 = v[x]
        if x == i + 1:
          if c2 != '[':
            break
        else:
          if c2 in {'0' .. '9'} + {';'}:
            discard # keep looking
          elif c2 == 'm':
            i = x + 1
            found = true
            break
          else:
            break
        inc x

      if found: # skip adding c
        continue
    res.add c
    inc i

  res

proc writeAndFlush(f: syncio.File, s: LogOutputStr) =
  try:
    f.write(s)
    f.flushFile()
  except CatchableError:
    logLoggingFailure(cstring(s), getCurrentException())

## Setup

proc setupLogLevel(level: LogLevel) =
  # TODO: Support per topic level configuratio
  topics_registry.setLogLevel(level)

proc setupLogFormat(format: LogFormat, color = true) =
  proc noOutputWriter(logLevel: LogLevel, msg: LogOutputStr) =
    discard

  proc stdoutOutputWriter(logLevel: LogLevel, msg: LogOutputStr) =
    writeAndFlush(syncio.stdout, msg)

  proc stdoutNoColorOutputWriter(logLevel: LogLevel, msg: LogOutputStr) =
    writeAndFlush(syncio.stdout, stripAnsi(msg))

  when defaultChroniclesStream.outputs.type.arity == 2:
    case format
    of LogFormat.Text:
      defaultChroniclesStream.outputs[0].writer =
        if color: stdoutOutputWriter else: stdoutNoColorOutputWriter
      defaultChroniclesStream.outputs[1].writer = noOutputWriter
    of LogFormat.Json:
      defaultChroniclesStream.outputs[0].writer = noOutputWriter
      defaultChroniclesStream.outputs[1].writer = stdoutOutputWriter
  else:
    {.
      warning:
        "the present module should be compiled with '-d:chronicles_default_output_device=dynamic' " &
        "and '-d:chronicles_sinks=\"textlines,json\"' options"
    .}

proc setupLog*(level: LogLevel, format: LogFormat) =
  ## Logging setup
  # Adhere to NO_COLOR initiative: https://no-color.org/
  let color =
    try:
      not parseBool(os.getEnv("NO_COLOR", "false"))
    except CatchableError:
      true

  setupLogLevel(level)
  setupLogFormat(format, color)
