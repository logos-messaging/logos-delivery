## This code has been copied and addapted from `status-im/nimbu-eth2` project.
## Link: https://github.com/status-im/nimbus-eth2/blob/c585b0a5b1ae4d55af38ad7f4715ad455e791552/beacon_chain/nimbus_binary_common.nim
import
  std/[typetraits, os, strutils, syncio, terminal, locks],
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

var
  logOutputLock: Lock
  logOutputFile = syncio.stdout
    ## Destination shared by all chronicles writers, on every thread. Any
    ## value other than stdout/stderr is a file opened (and owned) here.
  logOutputName = StdoutLogOutput

initLock(logOutputLock)

proc writeAndFlush(s: LogOutputStr) =
  # The lock keeps `setupLogOutput` from closing the file mid-write.
  {.cast(gcsafe).}:
    withLock(logOutputLock):
      try:
        logOutputFile.write(s)
        logOutputFile.flushFile()
      except CatchableError:
        logLoggingFailure(cstring(s), getCurrentException())

proc isConsole(f: syncio.File): bool =
  f == syncio.stdout or f == syncio.stderr

proc setupLogOutput(output: string): Result[void, string] =
  ## An empty `output` keeps the current destination: the output is process
  ## wide, so a node that does not ask for one must not move another's.
  {.cast(gcsafe).}:
    if output.len == 0 or output == logOutputName:
      return ok()

    when defaultChroniclesStream.outputs.type.arity != 2:
      return err("log output is not supported by this build: " & output)

    let file =
      case output
      of StdoutLogOutput:
        syncio.stdout
      of StderrLogOutput:
        syncio.stderr
      else:
        try:
          open(output, fmAppend)
        except IOError as e:
          return err("could not open log output file: " & output & ": " & e.msg)

    withLock(logOutputLock):
      if not logOutputFile.isConsole():
        logOutputFile.close()
      logOutputFile = file
      logOutputName = output
    return ok()

proc useColors(): bool =
  ## Colors only on a terminal, and never when NO_COLOR is set
  ## (https://no-color.org/).
  let noColorEnv =
    try:
      parseBool(os.getEnv("NO_COLOR", "false"))
    except CatchableError:
      false
  {.cast(gcsafe).}:
    return not noColorEnv and logOutputFile.isConsole() and isatty(logOutputFile)

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
    ## Binaries pass `-d:chronicles_sinks="textlines,json"` and
    ## `-d:chronicles_default_output_device=dynamic` (see their nim.cfg). Tests
    ## keep chronicles' single default sink, so the format stays as it is.
    discard

when defaultChroniclesStream.outputs.type.arity == 2:
  # Without this, records logged before `setupLog` (e.g. by a library host
  # that has not created a node yet) hit chronicles' unconfigured writer.
  setupLogFormat(LogFormat.TEXT, useColors())

proc setupLog*(
    level: LogLevel, format: LogFormat, output: string
): Result[void, string] =
  ## Logging setup. `output` is "stdout", "stderr", a file path (appended), or
  ## empty to keep the current destination (stdout until set).
  setupLogOutput(output).isOkOr:
    return err("could not set up log output: " & error)

  setupLogLevel(level)
  setupLogFormat(format, useColors())
  return ok()

proc setupLog*(level: LogLevel, format: LogFormat) =
  ## Logging setup keeping the current destination.
  setupLog(level, format, "").isOkOr:
    raiseAssert "keeping the log output cannot fail: " & error
