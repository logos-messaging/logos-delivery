{.push raises: [].}

import std/[strutils, options], regex, results
import
  ../retention_policy,
  ./retention_policy_time,
  ./retention_policy_capacity,
  ./retention_policy_size

proc new(
    T: type RetentionPolicy, retPolicy: string
): RetentionPolicyResult[Option[RetentionPolicy]] =
  let retPolicy = retPolicy.toLower

  # Validate the retention policy format
  if retPolicy == "" or retPolicy == "none":
    return ok(none(RetentionPolicy))

  const StoreMessageRetentionPolicyRegex = re2"^\w+:\d*\.?\d+((g|m)b)?$"
  if not retPolicy.match(StoreMessageRetentionPolicyRegex):
    return err("invalid 'store message retention policy' format: " & retPolicy)

  # Apply the retention policy, if any
  let rententionPolicyParts = retPolicy.split(":", 1)
  let
    policy = rententionPolicyParts[0]
    policyArgs = rententionPolicyParts[1]

  if policy == "time":
    var retentionTimeSeconds: int64
    try:
      retentionTimeSeconds = parseInt(policyArgs)
    except ValueError:
      return err("invalid time retention policy argument")

    let retPolicy: RetentionPolicy = TimeRetentionPolicy.new(retentionTimeSeconds)
    return ok(some(retPolicy))
  elif policy == "capacity":
    var retentionCapacity: int
    try:
      retentionCapacity = parseInt(policyArgs)
    except ValueError:
      return err("invalid capacity retention policy argument")

    let retPolicy: RetentionPolicy = CapacityRetentionPolicy.new(retentionCapacity)
    return ok(some(retPolicy))
  elif policy == "size":
    var retentionSize: string
    retentionSize = policyArgs

    # captures the size unit such as GB or MB
    let sizeUnit = retentionSize.substr(retentionSize.len - 2)
    # captures the string type number data of the size provided
    let sizeQuantityStr = retentionSize.substr(0, retentionSize.len - 3)
    # to hold the numeric value data of size
    var inptSizeQuantity: float
    var sizeQuantity: int64
    var sizeMultiplier: float

    try:
      inptSizeQuantity = parseFloat(sizeQuantityStr)
    except ValueError:
      return err("invalid size retention policy argument: " & getCurrentExceptionMsg())

    case sizeUnit
    of "gb":
      sizeMultiplier = 1024.0 * 1024.0 * 1024.0
    of "mb":
      sizeMultiplier = 1024.0 * 1024.0
    else:
      return err (
        """invalid size retention value unit: expected "Mb" or "Gb" but got """ &
        sizeUnit
      )

    # quantity is converted into bytes for uniform processing
    sizeQuantity = int64(inptSizeQuantity * sizeMultiplier)

    if sizeQuantity <= 0:
      return err("invalid size retention policy argument: a non-zero value is required")

    let retPolicy: RetentionPolicy = SizeRetentionPolicy.new(sizeQuantity)
    return ok(some(retPolicy))
  else:
    return err("unknown retention policy")

proc new*(
    T: typedesc[RetentionPolicy], retPolicies: seq[string]
): RetentionPolicyResult[seq[RetentionPolicy]] =
  var policies: seq[RetentionPolicy]
  for retPolicy in retPolicies:
    let policy = RetentionPolicy.new(retPolicy).valueOr:
      return err(error)
    if policy.isSome():
      policies.add(policy.get())
  return ok(policies)
