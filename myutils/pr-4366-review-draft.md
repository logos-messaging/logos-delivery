# Draft review — logos-messaging/logos-delivery#4366

Head: `e60c5fbb1429d7c7719d3da50a531d1292bc8134` · NOT posted. Lines are RIGHT-side lines of the PR head.

---

## 1. `logos_delivery/waku/rln/rln_evm/rln_evm.nim:294-296`

I wonder if we should also bound the timestamp against the wall clock before drawing the id. `reserve` moves `epochIndex` forward for any later epoch, so a single message stamped in the future (wrong units, skewed client clock through REST or lightpush) leaves the counter in that future epoch, and from then on every properly stamped message is refused as `EpochPassed` until the clock catches up or the node restarts. The validator already rejects anything beyond `rlnMaxTimestampGap`, but that happens after the id was drawn. Maybe sth like:

```suggestion
    if message.timestamp <= 0:
      return err(RlnError.permanent("the message has not been timestamped"))
    let messageTime = float64(message.timestamp) / 1e9
    if abs(getTime().toUnixFloat() - messageTime) > float64(rlnEvm.rlnMaxTimestampGap):
      return err(RlnError.permanent("the message timestamp is too far from the current time"))
    return await rlnEvm.generateRLNProofWithRootRefresh(
```

(the next line would then pass `messageTime`)

## 2. `logos_delivery/messaging/delivery_service/send_service/send_service.nim:448-458`

Two things here :)

- nit, I think we can keep the `valueOr` shape that the rest of the file uses.
- Now that the epoch comes from the task's timestamp, `BudgetExhausted` cannot recover on a later round: that epoch's budget never refills. Shall we fail the task in that case too, instead of retrying until `maxDeliveryTime` and reporting the generic "Unable to send within retry time window"?

```suggestion
  task.msg = (await self.waku.attachRlnProof(task.msg)).valueOr:
    case error.kind
    of RlnErrorKind.Permanent, RlnErrorKind.BudgetExhausted:
      task.state = DeliveryState.FailedToDeliver
      task.errorDesc = "Failed to attach RLN proof: " & $error
    else:
      debug "Failed to attach RLN proof, retrying next round",
        requestId = task.requestId, error = $error
    return false
```

Ideally without the `else`, listing every kind, so that the compiler tells us when a new kind needs a retry policy. wdyt?

## 3. `logos_delivery/messaging/delivery_service/send_service/send_service.nim:451`

not blocking. At this point `rateLimitManager.admit` already charged a slot for the task. I wonder if we should give it back when the attach fails for good, otherwise the rate limit manager counts budget for messages that never left.

## 4. `logos_delivery/waku/rln/rln_evm/rln_evm.nim:307-308`

I might be missing something but the admission path still asks for the quota of the wall-clock epoch (`rlnQuotaProvider` in `messaging_client.nim` passes `getTime()`), whereas the id is now drawn from the message timestamp's epoch. For a task parked in an exhausted epoch E, once the clock enters E+1 this reports a full budget, `admit` charges E+1, and then `reserve(E)` fails. Should the quota provider receive the task's timestamp? Maybe something to tackle in the follow-up PR that re-stamps parked tasks.

## 5. `logos_delivery/waku/rln/rln_evm/nonce_manager.nim:64-69`

I think an epoch that was already left behind should report its budget as spent, given that `reserve` refuses it. Returning 0 makes `quota` announce a full budget for an epoch we can no longer draw from.

```suggestion
proc spent*(n: NonceManager, epochIndex: uint64): Nonce =
  ## Message ids no longer available in `epochIndex`: the whole budget for an
  ## epoch already left behind, since `reserve` refuses it, and zero for a
  ## later one.
  if epochIndex < n.epochIndex:
    return n.nonceLimit
  if epochIndex > n.epochIndex:
    return 0
  return n.nextId
```

The `remaining == 20'u64` check in "a message in a later epoch starts that epoch's budget" would need to follow.

## 6. `logos_delivery/waku/rln/rln_evm/proof.nim:106`

not blocking, and it was already like that before this PR. The id is drawn before the proof is generated and it isn't given back if generation fails, so every retry of the same message spends another id while the rate limit manager charged it once. It matters a bit more now that the epoch is fixed by the timestamp. Perhaps worth a note for the upcoming persistent message-id store PR?

## 7. `logos_delivery/waku/rln/rln_evm/proof.nim:28`

nit, I wonder if we need two error types here. `NonceManagerError` only exists to be converted by `toRlnError`. Maybe `reserve` could return the bare `NonceManagerErrorKind` and we build the message at this point, or return `RlnError` directly.

## 8. `logos_delivery/waku/rln/rln_evm/proof.nim:80`

nit, `generateRLNProof` still returns a `string` error whereas `generateRLNProofWithRootRefresh` returns `RlnError`. If it is only kept for chat2, shall we align both so that we have a single error shape in the module?

## 9. `logos_delivery/waku/rln/rln_evm/rln_evm.nim:294`

Super nitpick ;P `ensureTimestampSet` only fills in a zero timestamp, so a negative one reaches this point and gets "has not been timestamped". Maybe "the message timestamp is not valid"?

## 10. `tests/messaging/test_rln_proof_attach.nim:161`

I think it'd be interesting to also have a send-service test for the new branch: a task whose attach fails as `Permanent` ends in `FailedToDeliver` and emits `MessageErrorEvent`, both from `send` and from `trySendMessages`. The cases added here only cover `attachRlnProof` directly.

## 11. `logos_delivery/waku/rln/rln_evm/nonce_manager.nim:64`

nit, `spent` has no side effects, so it can be a `func`. Applies elsewhere (`$`, `epochIndexOf`, `toRlnError`).
See https://status-im.github.io/nim-style-guide/language.proc.html

---

## Summary (review body)

Thanks for it! Aligning the id's epoch with the proof's epoch makes a lot of sense.

The only point I'd like to see sorted out before merging is the first one: a future-stamped message can leave the nonce manager in a future epoch and block every later send. The `BudgetExhausted` retry and the quota epoch mismatch are closely related and could also go in the follow-up PR. The rest are nitpicks :)
