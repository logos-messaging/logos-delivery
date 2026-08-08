## Adapted from status-im/nimbus-eth2 nimbus_binary_common.nim.
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

proc stripAnsi(v: string): string =
  ## chronicles colors are a compile-time property, so strip ANSI at runtime.
  var
    res = newStringOfCap(v.len)
    i: int

  while i < v.len:
    let c = v[i]
    if c == '\x1b':
      var
        x = i + 1
        found = false

      while x < v.len:
        let c2 = v[x]
        if x == i + 1:
          if c2 != '[':
            break
        else:
          if c2 in {'0' .. '9'} + {';'}:
            discard
          elif c2 == 'm':
            i = x + 1
            found = true
            break
          else:
            break
        inc x

      if found:
        continue
    res.add c
    inc i

  res

proc writeAndFlush(f: syncio.File, s: LogOutputStr) =
  try:
    f.write(s)
    f.flushFile()
  except IOError:
    logLoggingFailure(cstring(s), getCurrentException())

proc setupLogLevel(level: LogLevel) =
  # TODO: Support per topic level configuration
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
  # Adhere to NO_COLOR initiative: https://no-color.org/
  let color =
    try:
      not parseBool(os.getEnv("NO_COLOR", "false"))
    except ValueError:
      true

  setupLogLevel(level)
  setupLogFormat(format, color)
