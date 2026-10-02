{.push raises: [].}

## Persistent message id counter for the EVM backend.
##
## Holds, per identity, the last epoch the backend drew message ids in and the
## next unused id there, so a restart resumes the count instead of handing
## out ids that are already in sent proofs. One row per identity, in the
## node's `rln` persistency job.
##
## The row key is a tagged hash of the identity secret: rows of different
## identities stay apart, and the file cannot be linked to an on-chain
## membership without the secret.

import chronos, results, nimcrypto, libp2p/protobuf/minprotobuf
import brokers/broker_context
import logos_delivery/waku/persistency/persistency
import ./nonce_manager, ./protocol_types

const
  RlnJobId* = "rln"
  RlnCategory = "rln"
  MessageIdKeyTag = "logos-delivery/rln/message-id-store/v1"
    ## Hashed into every row key. Changing it strands every stored row, and a
    ## node upgraded in the middle of an epoch would draw from zero again.

type StoredMessageIds* = object
  epochIndex*: uint64 ## Last epoch ids were drawn in.
  nextId*: Nonce ## Next unused id in `epochIndex`.

proc messageIdKey*(idSecretHash: IdentitySecretHash): Key =
  ## Row key of one identity: `sha256(MessageIdKeyTag ‖ idSecretHash)`.
  var input = newSeqOfCap[byte](MessageIdKeyTag.len + idSecretHash.len)
  for c in MessageIdKeyTag:
    input.add(byte(c))
  input.add(idSecretHash)
  return key("message-id", sha256.digest(input).data)

proc encodeIds(epochIndex: uint64, nextId: Nonce): seq[byte] =
  var pb = initProtoBuffer()
  pb.write(1, epochIndex)
  pb.write(2, nextId)
  pb.finish()
  return pb.buffer

proc decodeIds(bytes: seq[byte]): Result[StoredMessageIds, string] =
  let pb = initProtoBuffer(bytes)
  var epochIndex, nextId: uint64
  let hasEpochIndex = pb.getField(1, epochIndex).valueOr:
    return err("epoch index: " & $error)
  let hasNextId = pb.getField(2, nextId).valueOr:
    return err("next id: " & $error)
  if not hasEpochIndex:
    return err("missing epoch index field")
  if not hasNextId:
    return err("missing next id field")
  return ok(StoredMessageIds(epochIndex: epochIndex, nextId: nextId))

proc openMessageIdStore*(brokerCtx: BrokerContext): Result[persistency.Job, string] =
  ## Opens the `rln` job of the persistency provided under `brokerCtx`. Fails
  ## while none is provided (before `Waku.start`) or when the job does not
  ## open. The first open blocks the calling thread while the job's worker
  ## thread opens its database.
  let p = GetPersistency.request(brokerCtx).valueOr:
    return err("no persistency provider: " & $error)
  let job = p.openJob(RlnJobId).valueOr:
    return err("could not open persistency job " & RlnJobId & ": " & $error)
  return ok(job)

proc loadMessageIds*(
    job: persistency.Job, key: Key
): Future[Result[Opt[StoredMessageIds], string]] {.async: (raises: [CancelledError]).} =
  ## The identity's stored row; none when it has never drawn an id. A row that
  ## does not decode is an error, never a fresh start.
  if job.isNil() or not job.running:
    return err("read message ids: store is closed")
  let stored =
    try:
      (await job.get(RlnCategory, key)).valueOr:
        return err("read message ids: " & $error)
    except CancelledError as e:
      raise e
    except CatchableError as e:
      return err("read message ids: unexpected error " & $e.name & ": " & e.msg)
  if stored.isNone():
    return ok(Opt.none(StoredMessageIds))
  let ids = decodeIds(stored.get()).valueOr:
    return err("decode message ids: " & error)
  return ok(Opt.some(ids))

proc saveMessageIds*(
    job: persistency.Job, key: Key, epochIndex: uint64, nextId: Nonce
): Future[Result[void, string]] {.async: (raises: [CancelledError]).} =
  ## Writes the identity's row and resolves once it is committed. A proof may
  ## carry an id only after the saved `nextId` is above it.
  if job.isNil() or not job.running:
    return err("write message ids: store is closed")
  try:
    (await job.putAcked(RlnCategory, key, encodeIds(epochIndex, nextId))).isOkOr:
      return err("write message ids: " & $error)
  except CancelledError as e:
    raise e
  except CatchableError as e:
    return err("write message ids: unexpected error " & $e.name & ": " & e.msg)
  return ok()
