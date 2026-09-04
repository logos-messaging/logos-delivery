{.push raises: [].}

import std/options
import results

export options, results

## Client-facing data types of the RLN Module API, mirroring the RLN-API spec
## (logos-lips `docs/anoncomms/raw/rln-api.md`). Flat and serializable on
## purpose: no chain dependencies, no FFI types, so the module can be consumed
## over any topology (direct Nim import or a C-ABI module boundary).

const
  RlnIdentifierSize* = 32
  RlnFieldElementSize* = 32
  RlnProofSize* = 128

type
  RegistryId* = string
    ## CAIP-10 account identifier selecting the registry deployment,
    ## e.g. "eip155:59144:0xb9cd..." or "logos:<network>:<64-hex>".

  RlnIdentifier* = array[RlnIdentifierSize, byte]
    ## Per-application identifier; MUST be unique per application sharing
    ## a registry (a collision lets one application spend another's budget).

  MembershipScope* = object
    ## Names the (registry, application) pair on every module call.
    ## The Module holds no defaults.
    registryId*: RegistryId
    rlnIdentifier*: RlnIdentifier

  RegistryOption* = object
    ## Registry-specific key-value registration option; "rate_limit"
    ## (decimal string) is the common key.
    key*: string
    value*: string

  RegistryOptions* = seq[RegistryOption]

  MembershipStatus* {.pure.} = enum
    Unknown
    Pending
    Failed
    Active
    GracePeriod
    Expired
    ErasedAwaitsWithdrawal
    Erased
    Slashed ## removed by slashing; the identity secret is publicly revealed

  Membership* = object
    membershipHash*: array[RlnFieldElementSize, byte]
    rateLimit*: uint64
    leafIndex*: uint64

  MembershipState* = object
    ## Merged registry + local view of the membership for a scope.
    ## `membership` is present once the Module knows the membership data.
    status*: MembershipStatus
    membership*: Option[Membership]

  EpochQuota* = object
    ## One consistent snapshot of the current epoch budget.
    ## `rateLimit == 0` means no usable membership for the scope, never a
    ## spent budget — disambiguate via `getMembershipState`.
    epochIndex*: uint64
    rateLimit*: uint64
    remaining*: uint64

  RateLimitProof* = object
    proof*: array[RlnProofSize, byte]
    root*: array[RlnFieldElementSize, byte]
    epoch*: array[RlnFieldElementSize, byte]
    externalNullifier*: array[RlnFieldElementSize, byte]
    shareX*: array[RlnFieldElementSize, byte]
    shareY*: array[RlnFieldElementSize, byte]
    nullifier*: array[RlnFieldElementSize, byte]

  ProofVerdict* {.pure.} = enum
    Valid
    Invalid
    Duplicate
    RateLimitViolation

  ValidationResult* = object
    ## An invalid proof is a verdict, not an error. `recoveredSecret` is the
    ## violator's identity secret, set only on `RateLimitViolation`.
    verdict*: ProofVerdict
    recoveredSecret*: Option[array[RlnFieldElementSize, byte]]

  RlnErrorKind* {.pure.} = enum
    NotReady ## the Module cannot serve the call yet; retry later
    Transient ## registry/RPC failure; retry permitted
    BudgetExhausted ## epoch rate limit spent; retry next epoch
    Permanent ## invalid input or unsupported extension; retrying cannot succeed

  RlnError* = object
    kind*: RlnErrorKind
    message*: string

func init*(
    T: type MembershipScope, registryId: RegistryId, rlnIdentifier: RlnIdentifier
): T =
  MembershipScope(registryId: registryId, rlnIdentifier: rlnIdentifier)

func init*(T: type RlnError, kind: RlnErrorKind, message = ""): T =
  RlnError(kind: kind, message: message)

func notReady*(T: type RlnError, message = ""): T =
  RlnError(kind: RlnErrorKind.NotReady, message: message)

func transient*(T: type RlnError, message = ""): T =
  RlnError(kind: RlnErrorKind.Transient, message: message)

func budgetExhausted*(T: type RlnError, message = ""): T =
  RlnError(kind: RlnErrorKind.BudgetExhausted, message: message)

func permanent*(T: type RlnError, message = ""): T =
  RlnError(kind: RlnErrorKind.Permanent, message: message)

func `$`*(e: RlnError): string =
  $e.kind & ": " & e.message

{.pop.}
