{.used.}

import std/[os, strutils], testutils/unittests, results, chronicles
import logos_delivery/waku/common/logging

suite "Logging output":
  let path =
    getTempDir() / ("logos_delivery_test_logging_" & $getCurrentProcessId() & ".log")

  teardown:
    check setupLog(logging.LogLevel.INFO, logging.LogFormat.TEXT, StdoutLogOutput).isOk()
    removeFile(path)

  test "logs are appended to the configured file":
    check setupLog(logging.LogLevel.INFO, logging.LogFormat.TEXT, path).isOk()
    info "log line written to file", marker = "test-log-output-marker"
    check setupLog(logging.LogLevel.INFO, logging.LogFormat.TEXT, StdoutLogOutput).isOk()

    let content = readFile(path)
    check:
      content.contains("test-log-output-marker")
      not content.contains("\x1b[")

  test "an empty output keeps the current destination":
    check setupLog(logging.LogLevel.INFO, logging.LogFormat.TEXT, path).isOk()
    check setupLog(logging.LogLevel.INFO, logging.LogFormat.JSON, "").isOk()
    info "kept destination", marker = "test-log-keep-marker"
    check setupLog(logging.LogLevel.INFO, logging.LogFormat.TEXT, StdoutLogOutput).isOk()

    check readFile(path).contains("test-log-keep-marker")

  test "an unwritable file path is reported as an error":
    let res = setupLog(
      logging.LogLevel.INFO,
      logging.LogFormat.TEXT,
      getTempDir() / "missing-dir" / "out.log",
    )
    check res.isErr()
    check setupLog(logging.LogLevel.INFO, logging.LogFormat.TEXT, StderrLogOutput).isOk()
