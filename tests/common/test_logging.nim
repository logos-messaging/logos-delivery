{.used.}

import std/[os, strutils, typetraits], testutils/unittests, results, chronicles
import logos_delivery/waku/common/logging

suite "Logging output":
  test "logs are appended to the configured file":
    when defaultChroniclesStream.outputs.type.arity != 2:
      skip()
      return
    let path = getTempDir() / "logos_delivery_test_logging.log"
    removeFile(path)

    check setupLog(logging.LogLevel.INFO, logging.LogFormat.TEXT, path).isOk()
    info "log line written to file", marker = "test-log-output-marker"
    check setupLog(logging.LogLevel.INFO, logging.LogFormat.TEXT, StdoutLogOutput).isOk()

    let content = readFile(path)
    check:
      content.contains("test-log-output-marker")
      not content.contains("\x1b[")
    removeFile(path)

  test "an unwritable file path is reported as an error":
    let res = setupLog(
      logging.LogLevel.INFO,
      logging.LogFormat.TEXT,
      getTempDir() / "missing-dir" / "out.log",
    )
    check res.isErr()
    check setupLog(logging.LogLevel.INFO, logging.LogFormat.TEXT, StderrLogOutput).isOk()
    check setupLog(logging.LogLevel.INFO, logging.LogFormat.TEXT, StdoutLogOutput).isOk()
