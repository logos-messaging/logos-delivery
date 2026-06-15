import logos_delivery/waku/compat/option_valueor
import chronicles, std/options, results
import logos_delivery/waku/factory/waku_conf
import chronos
import libp2p/[peerid, multiaddress, peerinfo, extended_peer_record]
import libp2p/protocols/kademlia/types
import libp2p/protocols/service_discovery/types as sd_types
import logos_delivery/waku/waku_core/peers

logScope:
  topics = "waku conf builder kademlia discovery"

type KademliaDiscoveryConf* = object
  bootstrapNodes*: seq[(PeerId, seq[MultiAddress])]
  servicesToAdvertise*: seq[ServiceInfo]
  servicesToDiscover*: seq[string]
  randomLookupInterval*: Duration
  serviceLookupInterval*: Duration
  kadDhtConfig*: KadDHTConfig
  discoConfig*: sd_types.ServiceDiscoveryConfig
  clientMode*: bool
  xprPublishing*: bool

const
  DefaultKadEnabled*: bool = false
  DefaultRandomLookupInterval* = chronos.seconds(60)
  DefaultServiceLookupInterval* = chronos.seconds(60)

#######################################
## Kademlia Discovery Config Builder ##
#######################################
type KademliaDiscoveryConfBuilder* = object
  enabled*: Option[bool]
  bootstrapNodes*: seq[string]
  servicesToAdvertise*: seq[(string, seq[byte])]
  servicesToDiscover*: seq[string]
  randomLookupInterval*: Option[Duration]
  serviceLookupInterval*: Option[Duration]

  # Top-level ServiceDiscovery.new flags
  clientMode*: Option[bool]
  xprPublishing*: Option[bool]

  # Full override (power users / code paths)
  kadDhtConfig*: Option[KadDHTConfig]
  discoConfig*: Option[sd_types.ServiceDiscoveryConfig]

  # ServiceDiscoveryConfig scalars (discoConfig)
  kadKRegister*: Option[int]
  kadKLookup*: Option[int]
  kadFLookup*: Option[int]
  kadFReturn*: Option[int]
  kadAdvertExpiry*: Option[Duration]
  kadAdvertCacheCap*: Option[uint64]
  kadOccupancyExp*: Option[float64]
  kadSafetyParam*: Option[float64]
  kadIpSimCoefficient*: Option[float64]
  kadRegistrationWindow*: Option[Duration]
  kadBucketsCount*: Option[int]

  # KadDHTConfig scalars (config)
  kadTimeout*: Option[Duration]
  kadBucketRefreshTime*: Option[Duration]
  kadRetries*: Option[int]
  kadReplication*: Option[int]
  kadAlpha*: Option[int]
  kadQuorum*: Option[int]
  kadProviderRecordCapacity*: Option[int]
  kadProvidedKeyCapacity*: Option[int]
  kadRepublishProvidedKeysInterval*: Option[Duration]
  kadCleanupProvidersInterval*: Option[Duration]
  kadProviderExpirationInterval*: Option[Duration]
  kadRecordExpirationInterval*: Option[Duration]
  kadCleanupDataEntriesInterval*: Option[Duration]
  kadHideConnectionStatus*: Option[bool]
  kadDisableBootstrapping*: Option[bool]
  kadProviderRejection*: Option[bool]
  kadMaxProvidersPerKey*: Option[int]  # use some(-1) or none for Opt.none (unlimited)

proc init*(T: type KademliaDiscoveryConfBuilder): KademliaDiscoveryConfBuilder =
  KademliaDiscoveryConfBuilder()

proc withEnabled*(b: var KademliaDiscoveryConfBuilder, enabled: bool) =
  b.enabled = some(enabled)

proc withBootstrapNodes*(
    b: var KademliaDiscoveryConfBuilder, bootstrapNodes: seq[string]
) =
  b.bootstrapNodes = bootstrapNodes

proc withServicesToAdvertise*(
    b: var KademliaDiscoveryConfBuilder, services: seq[(string, seq[byte])]
) =
  b.servicesToAdvertise = services

proc withServicesToDiscover*(
    b: var KademliaDiscoveryConfBuilder, services: seq[string]
) =
  b.servicesToDiscover = services

proc withRandomLookupInterval*(
    b: var KademliaDiscoveryConfBuilder, interval: Duration
) =
  b.randomLookupInterval = some(interval)

proc withServiceLookupInterval*(
    b: var KademliaDiscoveryConfBuilder, interval: Duration
) =
  b.serviceLookupInterval = some(interval)

proc withClientMode*(b: var KademliaDiscoveryConfBuilder, client: bool) =
  b.clientMode = some(client)

proc withXprPublishing*(b: var KademliaDiscoveryConfBuilder, publish: bool) =
  b.xprPublishing = some(publish)

# Disco config with*
proc withKadKRegister*(b: var KademliaDiscoveryConfBuilder, v: int) =
  b.kadKRegister = some(v)
proc withKadKLookup*(b: var KademliaDiscoveryConfBuilder, v: int) =
  b.kadKLookup = some(v)
proc withKadFLookup*(b: var KademliaDiscoveryConfBuilder, v: int) =
  b.kadFLookup = some(v)
proc withKadFReturn*(b: var KademliaDiscoveryConfBuilder, v: int) =
  b.kadFReturn = some(v)
proc withKadAdvertExpiry*(b: var KademliaDiscoveryConfBuilder, v: Duration) =
  b.kadAdvertExpiry = some(v)
proc withKadAdvertCacheCap*(b: var KademliaDiscoveryConfBuilder, v: uint64) =
  b.kadAdvertCacheCap = some(v)
proc withKadOccupancyExp*(b: var KademliaDiscoveryConfBuilder, v: float64) =
  b.kadOccupancyExp = some(v)
proc withKadSafetyParam*(b: var KademliaDiscoveryConfBuilder, v: float64) =
  b.kadSafetyParam = some(v)
proc withKadIpSimCoefficient*(b: var KademliaDiscoveryConfBuilder, v: float64) =
  b.kadIpSimCoefficient = some(v)
proc withKadRegistrationWindow*(b: var KademliaDiscoveryConfBuilder, v: Duration) =
  b.kadRegistrationWindow = some(v)
proc withKadBucketsCount*(b: var KademliaDiscoveryConfBuilder, v: int) =
  b.kadBucketsCount = some(v)

# KadDHT config with*
proc withKadTimeout*(b: var KademliaDiscoveryConfBuilder, v: Duration) =
  b.kadTimeout = some(v)
proc withKadBucketRefreshTime*(b: var KademliaDiscoveryConfBuilder, v: Duration) =
  b.kadBucketRefreshTime = some(v)
proc withKadRetries*(b: var KademliaDiscoveryConfBuilder, v: int) =
  b.kadRetries = some(v)
proc withKadReplication*(b: var KademliaDiscoveryConfBuilder, v: int) =
  b.kadReplication = some(v)
proc withKadAlpha*(b: var KademliaDiscoveryConfBuilder, v: int) =
  b.kadAlpha = some(v)
proc withKadQuorum*(b: var KademliaDiscoveryConfBuilder, v: int) =
  b.kadQuorum = some(v)
proc withKadProviderRecordCapacity*(b: var KademliaDiscoveryConfBuilder, v: int) =
  b.kadProviderRecordCapacity = some(v)
proc withKadProvidedKeyCapacity*(b: var KademliaDiscoveryConfBuilder, v: int) =
  b.kadProvidedKeyCapacity = some(v)
proc withKadRepublishProvidedKeysInterval*(b: var KademliaDiscoveryConfBuilder, v: Duration) =
  b.kadRepublishProvidedKeysInterval = some(v)
proc withKadCleanupProvidersInterval*(b: var KademliaDiscoveryConfBuilder, v: Duration) =
  b.kadCleanupProvidersInterval = some(v)
proc withKadProviderExpirationInterval*(b: var KademliaDiscoveryConfBuilder, v: Duration) =
  b.kadProviderExpirationInterval = some(v)
proc withKadRecordExpirationInterval*(b: var KademliaDiscoveryConfBuilder, v: Duration) =
  b.kadRecordExpirationInterval = some(v)
proc withKadCleanupDataEntriesInterval*(b: var KademliaDiscoveryConfBuilder, v: Duration) =
  b.kadCleanupDataEntriesInterval = some(v)
proc withKadHideConnectionStatus*(b: var KademliaDiscoveryConfBuilder, v: bool) =
  b.kadHideConnectionStatus = some(v)
proc withKadDisableBootstrapping*(b: var KademliaDiscoveryConfBuilder, v: bool) =
  b.kadDisableBootstrapping = some(v)
proc withKadProviderRejection*(b: var KademliaDiscoveryConfBuilder, v: bool) =
  b.kadProviderRejection = some(v)
proc withKadMaxProvidersPerKey*(b: var KademliaDiscoveryConfBuilder, v: int) =
  b.kadMaxProvidersPerKey = some(v)

proc withKadDhtConfig*(b: var KademliaDiscoveryConfBuilder, c: KadDHTConfig) =
  b.kadDhtConfig = some(c)

proc withDiscoConfig*(b: var KademliaDiscoveryConfBuilder, c: sd_types.ServiceDiscoveryConfig) =
  b.discoConfig = some(c)

proc build*(
    b: KademliaDiscoveryConfBuilder
): Result[Option[KademliaDiscoveryConf], string] =
  # Explicit disable wins: enabled=false disables regardless of bootstrap nodes.
  if b.enabled == some(false):
    return ok(none(KademliaDiscoveryConf))
  # Otherwise enabled if config-enabled or any bootstrap nodes are provided.
  if not b.enabled.get(DefaultKadEnabled) and b.bootstrapNodes.len == 0:
    return ok(none(KademliaDiscoveryConf))

  var parsedNodes: seq[(PeerId, seq[MultiAddress])]
  for nodeStr in b.bootstrapNodes:
    let (peerId, ma) = parseFullAddress(nodeStr).valueOr:
      return err("Failed to parse kademlia bootstrap node: " & error)
    parsedNodes.add((peerId, @[ma]))

  var servicesToAdvertise: seq[ServiceInfo]
  for (serviceId, data) in b.servicesToAdvertise:
    servicesToAdvertise.add(ServiceInfo(id: serviceId, data: data))

  let kadDht =
    if b.kadDhtConfig.isSome():
      b.kadDhtConfig.get()
    else:
      KadDHTConfig.new(
        timeout = b.kadTimeout.get(DefaultTimeout),
        bucketRefreshTime = b.kadBucketRefreshTime.get(DefaultBucketRefreshTime),
        retries = b.kadRetries.get(DefaultRetries),
        replication = b.kadReplication.get(DefaultReplication),
        alpha = b.kadAlpha.get(DefaultAlpha),
        quorum = b.kadQuorum.get(DefaultQuorum),
        providerRecordCapacity = b.kadProviderRecordCapacity.get(DefaultProviderRecordCapacity),
        providedKeyCapacity = b.kadProvidedKeyCapacity.get(DefaultProvidedKeyCapacity),
        republishProvidedKeysInterval = b.kadRepublishProvidedKeysInterval.get(
          DefaultRepublishInterval
        ),
        cleanupProvidersInterval = b.kadCleanupProvidersInterval.get(
          DefaultCleanupProvidersInterval
        ),
        providerExpirationInterval = b.kadProviderExpirationInterval.get(
          DefaultProviderExpirationInterval
        ),
        recordExpirationInterval = b.kadRecordExpirationInterval.get(
          DefaultRecordExpirationInterval
        ),
        cleanupDataEntriesInterval = b.kadCleanupDataEntriesInterval.get(
          DefaultCleanupDataEntriesInterval
        ),
        hideConnectionStatus = b.kadHideConnectionStatus.get(true),
        disableBootstrapping = b.kadDisableBootstrapping.get(false),
        providerRejection = b.kadProviderRejection.get(false),
        maxProvidersPerKey =
          if b.kadMaxProvidersPerKey.isSome() and b.kadMaxProvidersPerKey.get() > 0:
            Opt.some(b.kadMaxProvidersPerKey.get())
          else:
            Opt.none(int),
      )

  let discoC =
    if b.discoConfig.isSome():
      b.discoConfig.get()
    else:
      sd_types.ServiceDiscoveryConfig.new(
        kRegister = b.kadKRegister.get(sd_types.Default_K_register),
        kLookup = b.kadKLookup.get(sd_types.Default_K_lookup),
        fLookup = b.kadFLookup.get(sd_types.Default_F_lookup),
        fReturn = b.kadFReturn.get(sd_types.Default_F_return),
        advertExpiry = b.kadAdvertExpiry.get(sd_types.Default_E),
        advertCacheCap = b.kadAdvertCacheCap.get(sd_types.Default_C),
        occupancyExp = b.kadOccupancyExp.get(sd_types.Default_P_occ),
        safetyParam = b.kadSafetyParam.get(sd_types.Default_G),
        ipSimCoefficient = b.kadIpSimCoefficient.get(sd_types.Default_IpSimCoefficient),
        registrationWindow = b.kadRegistrationWindow.get(sd_types.Default_Delta),
        bucketsCount = b.kadBucketsCount.get(sd_types.Default_M_buckets),
      )

  return ok(
    some(
      KademliaDiscoveryConf(
        bootstrapNodes: parsedNodes,
        servicesToAdvertise: servicesToAdvertise,
        servicesToDiscover: b.servicesToDiscover,
        randomLookupInterval: b.randomLookupInterval.get(DefaultRandomLookupInterval),
        serviceLookupInterval: b.serviceLookupInterval.get(DefaultServiceLookupInterval),
        kadDhtConfig: kadDht,
        discoConfig: discoC,
        clientMode: b.clientMode.get(false),
        xprPublishing: b.xprPublishing.get(true),
      )
    )
  )
