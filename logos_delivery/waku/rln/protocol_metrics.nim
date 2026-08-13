{.push raises: [].}

import chronicles, metrics, metrics/chronos_httpserver, ../utils/collector

export metrics

logScope:
  topics = "waku rln"

func generateBucketsForHistogram*(length: int): seq[float64] =
  ## Generate a custom set of 5 buckets for a given length
  let numberOfBuckets = 5
  let stepSize = length / numberOfBuckets
  var buckets: seq[float64]
  for i in 1 .. numberOfBuckets:
    buckets.add(stepSize * i.toFloat())
  return buckets

declarePublicCounter(
  logos_delivery_rln_messages_total, "number of messages seen by the rln relay"
)

declarePublicCounter(
  logos_delivery_rln_spam_messages_total, "number of spam messages detected"
)
declarePublicCounter(
  logos_delivery_rln_invalid_messages_total,
  "number of invalid messages detected",
  ["type"],
)
# This metric will be useful in detecting the index of the root in the acceptable window of roots
declarePublicCounter(
  logos_delivery_rln_valid_messages_total,
  "number of valid messages with their roots tracked",
  ["shard"],
)
declarePublicCounter(
  logos_delivery_rln_errors_total,
  "number of errors detected while operating the rln relay",
  ["type"],
)
declarePublicCounter(
  logos_delivery_rln_proof_verification_total,
  "number of times the rln proofs are verified",
)
# this is a gauge so that we can set it based on the events we receive
declarePublicGauge(
  logos_delivery_rln_number_registered_memberships,
  "number of registered and active rln memberships",
)

# Timing metrics
declarePublicGauge(
  logos_delivery_rln_proof_verification_duration_seconds, "time taken to verify a proof"
)
declarePublicGauge(
  logos_delivery_rln_proof_generation_duration_seconds, "time taken to generate a proof"
)
declarePublicGauge(
  logos_delivery_rln_instance_creation_duration_seconds,
  "time taken to create an rln instance",
)
declarePublicGauge(
  logos_delivery_rln_membership_insertion_duration_seconds,
  "time taken to process a new membership registration",
)
declarePublicGauge(
  logos_delivery_rln_membership_credentials_import_duration_seconds,
  "time taken to import membership credentials",
)

declarePublicGauge(
  logos_delivery_rln_remaining_proofs_per_epoch,
  "number of proofs remaining to be generated for the current epoch",
)

declarePublicGauge(
  logos_delivery_rln_total_generated_proofs,
  "total number of proofs generated since the node started",
)

type RLNMetricsLogger = proc() {.gcsafe, raises: [Defect].}

proc getRlnMetricsLogger*(): RLNMetricsLogger =
  var logMetrics: RLNMetricsLogger

  var cumulativeErrors = 0.float64
  var cumulativeMessages = 0.float64
  var cumulativeSpamMessages = 0.float64
  var cumulativeInvalidMessages = 0.float64
  var cumulativeValidMessages = 0.float64
  var cumulativeProofsVerified = 0.float64
  var cumulativeProofsGenerated = 0.float64
  var cumulativeProofsRemaining = 100.float64
  var cumulativeRegisteredMember = 0.float64

  when defined(metrics):
    logMetrics = proc() =
      {.gcsafe.}:
        let freshErrorCount =
          parseAndAccumulate(logos_delivery_rln_errors_total, cumulativeErrors)
        let freshMsgCount =
          parseAndAccumulate(logos_delivery_rln_messages_total, cumulativeMessages)
        let freshSpamCount = parseAndAccumulate(
          logos_delivery_rln_spam_messages_total, cumulativeSpamMessages
        )
        let freshInvalidMsgCount = parseAndAccumulate(
          logos_delivery_rln_invalid_messages_total, cumulativeInvalidMessages
        )
        let freshValidMsgCount = parseAndAccumulate(
          logos_delivery_rln_valid_messages_total, cumulativeValidMessages
        )
        let freshProofsVerifiedCount = parseAndAccumulate(
          logos_delivery_rln_proof_verification_total, cumulativeProofsVerified
        )
        let freshProofsGeneratedCount = parseAndAccumulate(
          logos_delivery_rln_total_generated_proofs, cumulativeProofsGenerated
        )
        let freshProofsRemainingCount = parseAndAccumulate(
          logos_delivery_rln_remaining_proofs_per_epoch, cumulativeProofsRemaining
        )
        let freshRegisteredMemberCount = parseAndAccumulate(
          logos_delivery_rln_number_registered_memberships, cumulativeRegisteredMember
        )

        info "RLN relay metrics",
          messages = freshMsgCount,
          spamMessages = freshSpamCount,
          invalidMessages = freshInvalidMsgCount,
          validMessages = freshValidMsgCount,
          errors = freshErrorCount,
          proofsVerified = freshProofsVerifiedCount,
          proofsGenerated = freshProofsGeneratedCount,
          proofsRemaining = freshProofsRemainingCount,
          registeredMembers = freshRegisteredMemberCount

  return logMetrics
