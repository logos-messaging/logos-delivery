{.push raises: [].}

import std/options, results
import ../waku_core, ../common/paging

## Public API types

type
  ArchiveCursor* = WakuMessageHash

  ArchiveQuery* = object
    includeData*: bool
    pubsubTopic*: Option[PubsubTopic]
    contentTopics*: seq[ContentTopic]
    cursor*: Option[ArchiveCursor]
    startTime*: Option[Timestamp]
    endTime*: Option[Timestamp]
    hashes*: seq[WakuMessageHash]
    pageSize*: uint
    direction*: PagingDirection
    requestId*: string

  ArchiveResponse* = object
    hashes*: seq[WakuMessageHash]
    messages*: seq[WakuMessage]
    topics*: seq[PubsubTopic]
    cursor*: Option[ArchiveCursor]

  ArchiveErrorKind* {.pure.} = enum
    UNKNOWN = uint32(0)
    DRIVER_ERROR = uint32(1)
    INVALID_QUERY = uint32(2)

  ArchiveError* = object
    case kind*: ArchiveErrorKind
    of DRIVER_ERROR, INVALID_QUERY:
      # TODO: Add an enum to be able to distinguish between error causes
      cause*: string
    else:
      discard

  ArchiveResult* = Result[ArchiveResponse, ArchiveError]

proc `$`*(err: ArchiveError): string =
  case err.kind
  of ArchiveErrorKind.DRIVER_ERROR:
    "DRIVER_ERROR: " & err.cause
  of ArchiveErrorKind.INVALID_QUERY:
    "INVALID_QUERY: " & err.cause
  of ArchiveErrorKind.UNKNOWN:
    "UNKNOWN"

proc invalidQuery*(T: type ArchiveError, cause: string): T =
  ArchiveError(kind: ArchiveErrorKind.INVALID_QUERY, cause: cause)
