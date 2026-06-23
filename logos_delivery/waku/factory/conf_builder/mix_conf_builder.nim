import chronicles, std/options, results
import libp2p/crypto/crypto, libp2p/crypto/curve25519, libp2p_mix/curve25519
import ../waku_conf, logos_delivery/waku/waku_mix

logScope:
  topics = "waku conf builder mix"

##################################
## Mix Config Builder ##
##################################
type MixConfBuilder* = object
  enabled: Option[bool]
  mixKey: Option[string]
  mixNodes: seq[MixNodePubInfo]
  userMessageLimit: Option[int]
  disableSpamProtection: bool
  disableCoverTraffic: bool
  useOnchainLEZ: bool
  gifterService: bool
  gifterWalletAccount: string
  gifterNode: string
  gifterAllowlist: string
  gifterAuthKey: string

proc init*(T: type MixConfBuilder): MixConfBuilder =
  MixConfBuilder()

proc withEnabled*(b: var MixConfBuilder, enabled: bool) =
  b.enabled = some(enabled)

proc withMixKey*(b: var MixConfBuilder, mixKey: string) =
  b.mixKey = some(mixKey)

proc withMixNodes*(b: var MixConfBuilder, mixNodes: seq[MixNodePubInfo]) =
  b.mixNodes = mixNodes

proc withUserMessageLimit*(b: var MixConfBuilder, limit: int) =
  b.userMessageLimit = some(limit)

proc withDisableSpamProtection*(b: var MixConfBuilder, disable: bool) =
  b.disableSpamProtection = disable

proc withDisableCoverTraffic*(b: var MixConfBuilder, disable: bool) =
  b.disableCoverTraffic = disable

proc withUseOnchainLEZ*(b: var MixConfBuilder, use: bool) =
  b.useOnchainLEZ = use

proc withGifterService*(b: var MixConfBuilder, enabled: bool) =
  b.gifterService = enabled

proc withGifterWalletAccount*(b: var MixConfBuilder, account: string) =
  b.gifterWalletAccount = account

proc withGifterNode*(b: var MixConfBuilder, node: string) =
  b.gifterNode = node

proc withGifterAllowlist*(b: var MixConfBuilder, allowlist: string) =
  b.gifterAllowlist = allowlist

proc withGifterAuthKey*(b: var MixConfBuilder, authKey: string) =
  b.gifterAuthKey = authKey

proc build*(b: MixConfBuilder): Result[Option[MixConf], string] =
  if not b.enabled.get(false):
    return ok(none[MixConf]())
  else:
    if b.mixKey.isSome():
      let mixPrivKey = intoCurve25519Key(ncrutils.fromHex(b.mixKey.get()))
      let mixPubKey = public(mixPrivKey)
      return ok(
        some(
          MixConf(
            mixKey: mixPrivKey,
            mixPubKey: mixPubKey,
            mixNodes: b.mixNodes,
            userMessageLimit: b.userMessageLimit,
            disableSpamProtection: b.disableSpamProtection,
            disableCoverTraffic: b.disableCoverTraffic,
            useOnchainLEZ: b.useOnchainLEZ,
            gifterService: b.gifterService,
            gifterWalletAccount: b.gifterWalletAccount,
            gifterNode: b.gifterNode,
            gifterAllowlist: b.gifterAllowlist,
            gifterAuthKey: b.gifterAuthKey,
          )
        )
      )
    else:
      let (mixPrivKey, mixPubKey) = generateKeyPair().valueOr:
        return err("Generate key pair error: " & $error)
      return ok(
        some(
          MixConf(
            mixKey: mixPrivKey,
            mixPubKey: mixPubKey,
            mixNodes: b.mixNodes,
            userMessageLimit: b.userMessageLimit,
            disableSpamProtection: b.disableSpamProtection,
            disableCoverTraffic: b.disableCoverTraffic,
            useOnchainLEZ: b.useOnchainLEZ,
            gifterService: b.gifterService,
            gifterWalletAccount: b.gifterWalletAccount,
            gifterNode: b.gifterNode,
            gifterAllowlist: b.gifterAllowlist,
            gifterAuthKey: b.gifterAuthKey,
          )
        )
      )
