{.used.}
{.push raises: [].}

import stint

import
  logos_delivery/waku/
    [waku_keystore/protocol_types, waku_rln, waku_rln/protocol_types]

func fromStrToBytesLe*(v: string): seq[byte] =
  try:
    return @(hexToUint[256](v).toBytesLE())
  except ValueError:
    # this should never happen
    return @[]

func defaultIdentityCredential*(): IdentityCredential =
  # zero out the values we don't need
  return IdentityCredential(
    idTrapdoor: default(IdentityTrapdoor),
    idNullifier: default(IdentityNullifier),
    idSecretHash: fromStrToBytesLe(
      "7984f7c054ad7793d9f31a1e9f29eaa8d05966511e546bced89961eb8874ab9"
    ),
    idCommitment: fromStrToBytesLe(
      "51c31de3bff7e52dc7b2eb34fc96813bacf38bde92d27fe326ce5d8296322a7"
    ),
  )

{.pop.}
