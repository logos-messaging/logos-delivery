## Writes the results of the run as JUnit XML next to the test binary.
## Import it first: tests run while their modules initialize.

{.used.}

import std/[os, streams, strutils], unittest2
# tests/nim.cfg makes the chronicles sinks dynamic; importing logging here
# gives them a writer before any suite logs.
import logos_delivery/waku/common/logging
export logging

type JUnitReport = ref object of OutputFormatter
  junit: JUnitOutputFormatter

method suiteStarted(report: JUnitReport, suiteName: string) =
  report.junit.suiteStarted(suiteName)

method testStarted(report: JUnitReport, testName: string) =
  report.junit.testStarted(testName)

# The java-junit reader shows only the message attribute, which unittest2 fills
# from the last checkpoint.
method failureOccurred(
    report: JUnitReport, checkpoints: seq[string], stackTrace: string
) =
  report.junit.failureOccurred(@[checkpoints.join("\n")], stackTrace)

method testEnded(report: JUnitReport, testResult: TestResult) =
  report.junit.testEnded(testResult)

method suiteEnded(report: JUnitReport) =
  report.junit.suiteEnded()

method testRunEnded(report: JUnitReport) =
  report.junit.testRunEnded()

addOutputFormatter(
  JUnitReport(
    junit: newJUnitOutputFormatter(
      openFileStream(getAppFilename().changeFileExt("xml"), fmWrite)
    )
  )
)
