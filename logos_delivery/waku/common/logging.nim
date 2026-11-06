## This code has been copied and addapted from `status-im/nimbu-eth2` project.
## Link: https://github.com/status-im/nimbus-eth2/blob/c585b0a5b1ae4d55af38ad7f4715ad455e791552/beacon_chain/nimbus_binary_common.nim
import
  std/[typetraits, os, strutils, syncio],
  chronicles,
  chronicles/log_output,
  chronicles/topics_registry,
  results

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

const
  StdoutLogOutput* = "stdout"
  StderrLogOutput* = "stderr"

var logOutputFile = syncio.stdout
  ## Destination shared by all chronicles writers; any other value than
  ## stdout/stderr is a file opened (and owned) by `setupLog`.

proc writeAndFlush(s: LogOutputStr) =
  {.cast(gcsafe).}:
    try:
      logOutputFile.write(s)
      logOutputFile.flushFile()
    except CatchableError:
      logLoggingFailure(cstring(s), getCurrentException())

proc setupLogOutput(output: string): Result[void, string] =
  let file =
    case output
    of "", StdoutLogOutput:
      syncio.stdout
    of StderrLogOutput:
      syncio.stderr
    else:
      try:
        open(output, fmAppend)
      except IOError as e:
        return err("could not open log output file: " & output & ": " & e.msg)

  if logOutputFile != syncio.stdout and logOutputFile != syncio.stderr:
    logOutputFile.close()
  logOutputFile = file
  return ok()

proc setupLogLevel(level: LogLevel) =
  # TODO: Support per topic level configuratio
  topics_registry.setLogLevel(level)

proc setupLogFormat(format: LogFormat, color = true) =
  proc noOutputWriter(logLevel: LogLevel, msg: LogOutputStr) =
    discard

  proc outputWriter(logLevel: LogLevel, msg: LogOutputStr) =
    writeAndFlush(msg)

  proc noColorOutputWriter(logLevel: LogLevel, msg: LogOutputStr) =
    writeAndFlush(stripAnsi(msg))

  when defaultChroniclesStream.outputs.type.arity == 2:
    case format
    of LogFormat.Text:
      defaultChroniclesStream.outputs[0].writer =
        if color: outputWriter else: noColorOutputWriter
      defaultChroniclesStream.outputs[1].writer = noOutputWriter
    of LogFormat.Json:
      defaultChroniclesStream.outputs[0].writer = noOutputWriter
      defaultChroniclesStream.outputs[1].writer = outputWriter
  else:
    {.
      warning:
        "the present module should be compiled with '-d:chronicles_default_output_device=dynamic' " &
        "and '-d:chronicles_sinks=\"textlines,json\"' options"
    .}

when defaultChroniclesStream.outputs.type.arity == 2:
  # Without this, records logged before `setupLog` (e.g. by a library host
  # that has not created a node yet) hit chronicles' unconfigured writer.
  setupLogFormat(LogFormat.TEXT)

proc setupLog*(
    level: LogLevel, format: LogFormat, output: string
): Result[void, string] =
  ## Logging setup. `output` is "stdout", "stderr" or a file path (appended).
  setupLogOutput(output).isOkOr:
    return err("could not set up log output: " & error)

  # Adhere to NO_COLOR initiative: https://no-color.org/
  let noColorEnv =
    try:
      parseBool(os.getEnv("NO_COLOR", "false"))
    except CatchableError:
      false
  # Files never get ANSI colors.
  let color = not noColorEnv and output in ["", StdoutLogOutput, StderrLogOutput]

  setupLogLevel(level)
  setupLogFormat(format, color)
  return ok()

proc setupLog*(level: LogLevel, format: LogFormat) =
  ## Logging setup writing to stdout.
  discard setupLog(level, format, StdoutLogOutput)
