## Runs `getaddrinfo` off the event loop: it blocks for as long as the host's
## resolver takes, which would stall every other task.
{.push raises: [].}

import std/[nativesockets, net, strutils, typedthreads]
import chronos, chronos/threadsync, chronicles, results

logScope:
  topics = "waku host resolver"

const
  MaxHostLen = 256
  MaxResolvedLen = 512
  MaxErrorLen = 256

type ResolveJob = object
  host: array[MaxHostLen, char]
  domain: Domain
  resolved: array[MaxResolvedLen, char] ## NUL terminated, comma separated addresses
  found: bool
  error: array[MaxErrorLen, char] ## NUL terminated reason when `found` is false
  signal: ThreadSignalPtr

type ResolveThread = Thread[ptr ResolveJob]

proc recordError(job: ptr ResolveJob, text: string) =
  for i in 0 ..< min(text.len, job.error.len - 1):
    job.error[i] = text[i]

proc resolveWorker(job: ptr ResolveJob) {.thread, nimcall.} =
  ## Runs on a bare OS thread, where chronicles is not safe and no string can
  ## cross to the event loop. A failure is therefore recorded in the job's
  ## fixed buffer and reported by `reapResolver`, as the persistency backend
  ## thread does with its `errBuf`.
  try:
    ## Hints are built here rather than through the `domain` overload, which
    ## adds AI_V4MAPPED for AF_INET6 and would answer an IPv6 lookup of an
    ## IPv4-only name with a mapped address.
    let hints = AddrInfo(
      ai_family: toInt(job.domain),
      ai_socktype: toInt(SOCK_STREAM),
      ai_protocol: toInt(IPPROTO_TCP),
    )
    let addrInfo = getAddrInfo($cast[cstring](addr job.host[0]), Port(0), hints)
    if not addrInfo.isNil():
      ## Every address is kept, in the resolver's order, so that a caller can
      ## fall back from one to the next.
      var joined = ""
      var node = addrInfo
      while not node.isNil():
        ## The `var string` overload formats through inet_ntop. The one-argument
        ## overload uses inet_ntoa for IPv4, whose buffer is a single static on
        ## musl and macOS, and several workers may run at once.
        var text = newString(46)
        getAddrString(node.ai_addr, text)
        let candidate =
          if joined.len == 0:
            text
          else:
            joined & "," & text
        if text.len > 0 and text notin joined.split(',') and
            candidate.len < job.resolved.len:
          joined = candidate
        node = node.ai_next

      for i in 0 ..< joined.len:
        job.resolved[i] = joined[i]
      job.found = joined.len > 0
      freeAddrInfo(addrInfo)
  except Exception as e:
    job.recordError(e.msg)

  discard job.signal.fireSync()

proc reapResolver(
    job: ptr ResolveJob,
    thread: ptr ResolveThread,
    res: Future[Result[seq[string], string]].Raising([CancelledError]),
) {.async: (raises: []).} =
  ## Owns the job and the thread until the worker is done, even when the caller
  ## was cancelled, so that nothing is freed under a running thread.
  try:
    await job.signal.wait()
  except CatchableError:
    discard

  joinThread(thread[])

  let host = $cast[cstring](addr job.host[0])
  let outcome =
    if job.found:
      Result[seq[string], string].ok(($cast[cstring](addr job.resolved[0])).split(','))
    else:
      let reason = $cast[cstring](addr job.error[0])
      Result[seq[string], string].err(
        "could not resolve the host " & host & ": " &
          (if reason.len > 0: reason else: "no address")
      )

  discard job.signal.close()
  deallocShared(thread)
  deallocShared(job)

  if not res.finished():
    res.complete(outcome)

proc getAddrInfoAsync*(
    host: string, domain: Domain = Domain.AF_UNSPEC
): Future[Result[seq[string], string]] {.async: (raises: [CancelledError]).} =
  ## The IP texts of `host` from the OS resolver, in its order and without
  ## duplicates. `err` when the host is unknown or the thread cannot start.
  if host.len == 0 or host.len >= MaxHostLen:
    return err("the host name length is out of range: " & $host.len)

  let signal = ThreadSignalPtr.new().valueOr:
    warn "Could not create the host resolver signal", host, error = error
    return err("could not create the resolver signal: " & error)

  let job = cast[ptr ResolveJob](allocShared0(sizeof(ResolveJob)))
  job.signal = signal
  job.domain = domain
  for i in 0 ..< host.len:
    job.host[i] = host[i]

  let thread = cast[ptr ResolveThread](allocShared0(sizeof(ResolveThread)))
  try:
    createThread(thread[], resolveWorker, job)
  except CatchableError as e:
    discard signal.close()
    deallocShared(thread)
    deallocShared(job)
    warn "Could not start the host resolver thread", host, error = e.msg
    return err("could not start the resolver thread: " & e.msg)

  let res = Future[Result[seq[string], string]].Raising([CancelledError]).init(
      "getAddrInfoAsync"
    )
  asyncSpawn reapResolver(job, thread, res)

  return await res
