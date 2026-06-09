# This implementation is originally taken from nim-eth keyfile module https://github.com/status-im/nim-eth/blob/master/eth/keyfile and adapted to
# - create keyfiles for arbitrary-long input byte data (rather than fixed-size private keys)
# - allow storage of multiple keyfiles (encrypted with different passwords) in same file and iteration among successful decryptions
# - enable/disable at compilation time the keyfile id and version fields

{.push raises: [].}

import
  std/[os, strutils, json, sequtils],
  nimcrypto/[bcmode, hmac, rijndael, pbkdf2, sha2, sysrand, utils, keccak, scrypt],
  results,
  eth/keys,
  eth/keyfile/uuid

export results

const
  # Version 3 constants
  SaltSize = 16
  DKLen = 32
  MaxDKLen = 128
  ScryptR = 1
  ScryptP = 8
  Pbkdf2WorkFactor = 1_000_000
  ScryptWorkFactor = 262_144

type
  KeyFileError* = enum
    KeyfileRandomError = "keyfile error: Random generator error"
    KeyfileUuidError = "keyfile error: UUID generator error"
    KeyfileBufferOverrun = "keyfile error: Supplied buffer is too small"
    KeyfileIncorrectDKLen =
      "keyfile error: `dklen` parameter is 0 or more then MaxDKLen"
    KeyfileMalformedError = "keyfile error: JSON has incorrect structure"
    KeyfileNotImplemented = "keyfile error: Feature is not implemented"
    KeyfileNotSupported = "keyfile error: Feature is not supported"
    KeyfileEmptyMac =
      "keyfile error: `mac` parameter is zero length or not in hexadecimal form"
    KeyfileEmptyCiphertext =
      "keyfile error: `ciphertext` parameter is zero length or not in hexadecimal format"
    KeyfileEmptySalt =
      "keyfile error: `salt` parameter is zero length or not in hexadecimal format"
    KeyfileEmptyIV =
      "keyfile error: `cipherparams.iv` parameter is zero length or not in hexadecimal format"
    KeyfileIncorrectIV =
      "keyfile error: Size of IV vector is not equal to cipher block size"
    KeyfilePrfNotSupported = "keyfile error: PRF algorithm for PBKDF2 is not supported"
    KeyfileKdfNotSupported = "keyfile error: KDF algorithm is not supported"
    KeyfileCipherNotSupported = "keyfile error: `cipher` parameter is not supported"
    KeyfileIncorrectMac = "keyfile error: `mac` verification failed"
    KeyfileScryptBadParam = "keyfile error: bad scrypt's parameters"
    KeyfileOsError = "keyfile error: OS specific error"
    KeyfileIoError = "keyfile error: IO specific error"
    KeyfileJsonError = "keyfile error: JSON encoder/decoder error"
    KeyfileDoesNotExist = "keyfile error: file does not exist"

  KdfKind* = enum
    PBKDF2 ## PBKDF2
    SCRYPT ## SCRYPT

  HashKind* = enum
    HashNoSupport
    HashSHA2_224
    HashSHA2_256
    HashSHA2_384
    HashSHA2_512
    HashKECCAK224
    HashKECCAK256
    HashKECCAK384
    HashKECCAK512
    HashSHA3_224
    HashSHA3_256
    HashSHA3_384
    HashSHA3_512

  CryptKind* = enum
    CipherNoSupport ## Cipher not supported
    AES128CTR ## AES-128-CTR

  CipherParams = object
    iv: seq[byte]

  Cipher = object
    kind: CryptKind
    params: CipherParams
    text: seq[byte]

  Crypto = object
    kind: KdfKind
    cipher: Cipher
    kdfParams: JsonNode
    mac: seq[byte]

  ScryptParams* = object
    dklen: int
    n, p, r: int
    salt: string

  Pbkdf2Params* = object
    dklen: int
    c: int
    prf: HashKind
    salt: string

  DKey = array[DKLen, byte]
  KfResult*[T] = Result[T, KeyFileError]

  # basic types for building Keystore JSON
  CypherParams = object
    iv: string

  CryptoNew = object
    cipher: string
    cipherparams: CypherParams
    ciphertext: string
    kdf: string
    kdfparams: JsonNode
    mac: string

  KeystoreEntry = object
    crypto: CryptoNew
    id: string
    version: string

const
  SupportedHashes = [
    "sha224", "sha256", "sha384", "sha512", "keccak224", "keccak256", "keccak384",
    "keccak512", "sha3_224", "sha3_256", "sha3_384", "sha3_512",
  ]

  SupportedHashesKinds = [
    HashSHA2_224, HashSHA2_256, HashSHA2_384, HashSHA2_512, HashKECCAK224,
    HashKECCAK256, HashKECCAK384, HashKECCAK512, HashSHA3_224, HashSHA3_256,
    HashSHA3_384, HashSHA3_512,
  ]

  # When true, the keyfile json will contain "version" and "id" fields, respectively. Default to false.
  VersionInKeyfile: bool = false
  IdInKeyfile: bool = false

proc mapErrTo[T, E](r: Result[T, E], v: static KeyFileError): KfResult[T] =
  r.mapErr(
    proc(e: E): KeyFileError =
      v
  )

proc `$`(k: KdfKind): string =
  case k
  of SCRYPT:
    return "scrypt"
  else:
    return "pbkdf2"

proc `$`(k: CryptKind): string =
  case k
  of AES128CTR:
    return "aes-128-ctr"
  else:
    return "aes-128-ctr"

# Parses the prf name to HashKind
proc getPrfHash(prf: string): HashKind =
  let p = prf.toLowerAscii()
  if p.startsWith("hmac-"):
    var hash = p[5 ..^ 1]
    var res = SupportedHashes.find(hash)
    if res >= 0:
      return SupportedHashesKinds[res]
  return HashNoSupport

# Parses the cipher name to CryptoKind
proc getCipher(c: string): CryptKind =
  var cl = c.toLowerAscii()
  if cl == "aes-128-ctr":
    return AES128CTR
  else:
    return CipherNoSupport

# Key derivation routine for PBKDF2
proc deriveKey(
    password: string,
    salt: string,
    kdfkind: KdfKind,
    hashkind: HashKind,
    workfactor: int,
): KfResult[DKey] =
  if kdfkind == PBKDF2:
    var output: DKey
    var c = if workfactor == 0: Pbkdf2WorkFactor else: workfactor
    case hashkind
    of HashSHA2_224:
      var ctx: HMAC[sha224]
      discard ctx.pbkdf2(password, salt, c, output)
      ctx.clear()
      ok(output)
    of HashSHA2_256:
      var ctx: HMAC[sha256]
      discard ctx.pbkdf2(password, salt, c, output)
      ctx.clear()
      ok(output)
    of HashSHA2_384:
      var ctx: HMAC[sha384]
      discard ctx.pbkdf2(password, salt, c, output)
      ctx.clear()
      ok(output)
    of HashSHA2_512:
      var ctx: HMAC[sha512]
      discard ctx.pbkdf2(password, salt, c, output)
      ctx.clear()
      ok(output)
    of HashKECCAK224:
      var ctx: HMAC[keccak224]
      discard ctx.pbkdf2(password, salt, c, output)
      ctx.clear()
      ok(output)
    of HashKECCAK256:
      var ctx: HMAC[keccak256]
      discard ctx.pbkdf2(password, salt, c, output)
      ctx.clear()
      ok(output)
    of HashKECCAK384:
      var ctx: HMAC[keccak384]
      discard ctx.pbkdf2(password, salt, c, output)
      ctx.clear()
      ok(output)
    of HashKECCAK512:
      var ctx: HMAC[keccak512]
      discard ctx.pbkdf2(password, salt, c, output)
      ctx.clear()
      ok(output)
    of HashSHA3_224:
      var ctx: HMAC[sha3_224]
      discard ctx.pbkdf2(password, salt, c, output)
      ctx.clear()
      ok(output)
    of HashSHA3_256:
      var ctx: HMAC[sha3_256]
      discard ctx.pbkdf2(password, salt, c, output)
      ctx.clear()
      ok(output)
    of HashSHA3_384:
      var ctx: HMAC[sha3_384]
      discard ctx.pbkdf2(password, salt, c, output)
      ctx.clear()
      ok(output)
    of HashSHA3_512:
      var ctx: HMAC[sha3_512]
      discard ctx.pbkdf2(password, salt, c, output)
      ctx.clear()
      ok(output)
    else:
      err(KeyfilePrfNotSupported)
  else:
    err(KeyfileNotImplemented)

# Scrypt wrapper
func scrypt[T, M](
    password: openArray[T],
    salt: openArray[M],
    N, r, p: int,
    output: var openArray[byte],
): int =
  let (xyvLen, bLen) = scryptCalc(N, r, p)
  var xyv = newSeq[uint32](xyvLen)
  var b = newSeq[byte](bLen)
  scrypt(password, salt, N, r, p, xyv, b, output)

# Key derivation routine for Scrypt
proc deriveKey(password: string, salt: string, workFactor, r, p: int): KfResult[DKey] =
  let wf = if workFactor == 0: ScryptWorkFactor else: workFactor
  var output: DKey
  if scrypt(password, salt, wf, r, p, output) == 0:
    return err(KeyfileScryptBadParam)

  return ok(output)

# Encryption routine
proc encryptData(
    plaintext: openArray[byte],
    cryptkind: CryptKind,
    key: openArray[byte],
    iv: openArray[byte],
): KfResult[seq[byte]] =
  if cryptkind == AES128CTR:
    var ciphertext = newSeqWith(plaintext.len, 0.byte)
    var ctx: CTR[aes128]
    ctx.init(toOpenArray(key, 0, 15), iv)
    ctx.encrypt(plaintext, ciphertext)
    ctx.clear()
    ok(ciphertext)
  else:
    err(KeyfileNotImplemented)

# Decryption routine
proc decryptData(
    ciphertext: openArray[byte],
    cryptkind: CryptKind,
    key: openArray[byte],
    iv: openArray[byte],
): KfResult[seq[byte]] =
  if cryptkind == AES128CTR:
    if len(iv) != aes128.sizeBlock:
      return err(KeyfileIncorrectIV)
    var plaintext = newSeqWith(ciphertext.len, 0.byte)
    var ctx: CTR[aes128]
    ctx.init(toOpenArray(key, 0, 15), iv)
    ctx.decrypt(ciphertext, plaintext)
    ctx.clear()
    ok(plaintext)
  else:
    err(KeyfileNotImplemented)

# Encodes KDF parameters in JSON
proc kdfParams(kdfkind: KdfKind, salt: string, workfactor: int): KfResult[JsonNode] =
  if kdfkind == SCRYPT:
    let wf = if workfactor == 0: ScryptWorkFactor else: workfactor
    ok(%*{"dklen": DKLen, "n": wf, "r": ScryptR, "p": ScryptP, "salt": salt})
  elif kdfkind == PBKDF2:
    let wf = if workfactor == 0: Pbkdf2WorkFactor else: workfactor
    ok(%*{"dklen": DKLen, "c": wf, "prf": "hmac-sha256", "salt": salt})
  else:
    err(KeyfileNotImplemented)

# Decodes hex strings to byte sequences
proc decodeHex*(m: string): seq[byte] =
  if len(m) > 0:
    try:
      return utils.fromHex(m)
    except CatchableError:
      return newSeq[byte]()
  else:
    return newSeq[byte]()

# Parses the salt from hex string to byte string
proc decodeSalt(m: string): string =
  var sarr: seq[byte]
  if len(m) > 0:
    try:
      sarr = utils.fromHex(m)
      var output = newString(len(sarr))
      copyMem(addr output[0], addr sarr[0], len(sarr))
      return output
    except CatchableError:
      return ""
  else:
    return ""

# Compares the message authentication code
proc compareMac(m1: openArray[byte], m2: openArray[byte]): bool =
  if len(m1) == len(m2) and len(m1) > 0:
    return equalMem(unsafeAddr m1[0], unsafeAddr m2[0], len(m1))
  else:
    return false

# Creates a keyfile for secret encrypted with password according to the other parameters
# Returns keyfile in JSON according to Web3 Secure storage format (here, differently than standard, version and id are optional)
proc createKeyFileJson*(
    secret: openArray[byte],
    password: string,
    version: int = 3,
    cryptkind: CryptKind = AES128CTR,
    kdfkind: KdfKind = PBKDF2,
    workfactor: int = 0,
): KfResult[JsonNode] =
  ## Create JSON object with keyfile structure.
  ##
  ## ``secret`` - secret data, which will be stored
  ## ``password`` - encryption password
  ## ``outjson`` - result JSON object
  ## ``version`` - version of keyfile format (default is 3)
  ## ``cryptkind`` - algorithm for encryption
  ## (default is AES128-CTR)
  ## ``kdfkind`` - algorithm for key deriviation function (default is PBKDF2)
  ## ``workfactor`` - Key deriviation function work factor, 0 is to use
  ## default workfactor.
  var iv: array[aes128.sizeBlock, byte]
  var salt: array[SaltSize, byte]
  var saltstr = newString(SaltSize)
  if randomBytes(iv) != aes128.sizeBlock:
    return err(KeyfileRandomError)
  if randomBytes(salt) != SaltSize:
    return err(KeyfileRandomError)
  copyMem(addr saltstr[0], addr salt[0], SaltSize)

  let u = ?uuidGenerate().mapErrTo(KeyfileUuidError)

  let
    dkey =
      case kdfkind
      of PBKDF2:
        ?deriveKey(password, saltstr, kdfkind, HashSHA2_256, workfactor)
      of SCRYPT:
        ?deriveKey(password, saltstr, workfactor, ScryptR, ScryptP)

    ciphertext = ?encryptData(secret, cryptkind, dkey, iv)

  var ctx: keccak256
  ctx.init()
  ctx.update(toOpenArray(dkey, 16, 31))
  ctx.update(ciphertext)
  var mac = ctx.finish()
  ctx.clear()

  let params = ?kdfParams(kdfkind, toHex(salt, true), workfactor)

  var obj = KeystoreEntry(
    crypto: CryptoNew(
      cipher: $cryptkind,
      cipherparams: CypherParams(iv: toHex(iv, true)),
      ciphertext: toHex(ciphertext, true),
      kdf: $kdfkind,
      kdfparams: params,
      mac: toHex(mac.data, true),
    )
  )

  let json = %*obj
  if IdInKeyfile:
    json.add("id", %($u))
  if VersionInKeyfile:
    json.add("version", %version)

  ok(json)

# Parses Cipher JSON information
proc decodeCrypto(n: JsonNode): KfResult[Crypto] =
  var crypto = n.getOrDefault("crypto")
  if isNil(crypto):
    return err(KeyfileMalformedError)

  var kdf = crypto.getOrDefault("kdf")
  if isNil(kdf):
    return err(KeyfileMalformedError)

  var c: Crypto
  case kdf.getStr()
  of "pbkdf2":
    c.kind = PBKDF2
  of "scrypt":
    c.kind = SCRYPT
  else:
    return err(KeyfileKdfNotSupported)

  var cipherparams = crypto.getOrDefault("cipherparams")
  if isNil(cipherparams):
    return err(KeyfileMalformedError)

  c.cipher.kind = getCipher(crypto.getOrDefault("cipher").getStr())
  c.cipher.params.iv = decodeHex(cipherparams.getOrDefault("iv").getStr())
  c.cipher.text = decodeHex(crypto.getOrDefault("ciphertext").getStr())
  c.mac = decodeHex(crypto.getOrDefault("mac").getStr())
  c.kdfParams = crypto.getOrDefault("kdfparams")

  if c.cipher.kind == CipherNoSupport:
    return err(KeyfileCipherNotSupported)
  if len(c.cipher.text) == 0:
    return err(KeyfileEmptyCiphertext)
  if len(c.mac) == 0:
    return err(KeyfileEmptyMac)
  if isNil(c.kdfParams):
    return err(KeyfileMalformedError)

  return ok(c)

# Parses PNKDF2 JSON parameters
proc decodePbkdf2Params(params: JsonNode): KfResult[Pbkdf2Params] =
  var p: Pbkdf2Params
  p.salt = decodeSalt(params.getOrDefault("salt").getStr())
  if len(p.salt) == 0:
    return err(KeyfileEmptySalt)

  p.dklen = params.getOrDefault("dklen").getInt()
  p.c = params.getOrDefault("c").getInt()
  p.prf = getPrfHash(params.getOrDefault("prf").getStr())

  if p.prf == HashNoSupport:
    return err(KeyfilePrfNotSupported)
  if p.dklen == 0 or p.dklen > MaxDKLen:
    return err(KeyfileIncorrectDKLen)

  return ok(p)

# Parses JSON Scrypt parameters
proc decodeScryptParams(params: JsonNode): KfResult[ScryptParams] =
  var p: ScryptParams
  p.salt = decodeSalt(params.getOrDefault("salt").getStr())
  if len(p.salt) == 0:
    return err(KeyfileEmptySalt)

  p.dklen = params.getOrDefault("dklen").getInt()
  p.n = params.getOrDefault("n").getInt()
  p.p = params.getOrDefault("p").getInt()
  p.r = params.getOrDefault("r").getInt()

  if p.dklen == 0 or p.dklen > MaxDKLen:
    return err(KeyfileIncorrectDKLen)

  return ok(p)

# Decrypts data
func decryptSecret(crypto: Crypto, dkey: DKey): KfResult[seq[byte]] =
  var ctx: keccak256
  ctx.init()
  ctx.update(toOpenArray(dkey, 16, 31))
  ctx.update(crypto.cipher.text)
  var mac = ctx.finish()
  ctx.clear()
  if not compareMac(mac.data, crypto.mac):
    return err(KeyfileIncorrectMac)

  let plaintext =
    ?decryptData(crypto.cipher.text, crypto.cipher.kind, dkey, crypto.cipher.params.iv)

  ok(plaintext)

# Parse JSON keyfile and decrypts its content using password
proc decodeKeyFileJson*(j: JsonNode, password: string): KfResult[seq[byte]] =
  ## Decode secret from keyfile json object ``j`` using
  ## password string ``password``.
  let crypto = ?decodeCrypto(j)

  case crypto.kind
  of PBKDF2:
    let params = ?decodePbkdf2Params(crypto.kdfParams)
    let dkey = ?deriveKey(password, params.salt, PBKDF2, params.prf, params.c)
    return decryptSecret(crypto, dkey)
  of SCRYPT:
    let params = ?decodeScryptParams(crypto.kdfParams)
    let dkey = ?deriveKey(password, params.salt, params.n, params.r, params.p)
    return decryptSecret(crypto, dkey)

# Loads the file at pathname, decrypts and returns all keyfiles encrypted under password
proc loadKeyFiles*(
    pathname: string, password: string
): KfResult[seq[KfResult[seq[byte]]]] =
  ## Load and decode data from file with pathname
  ## ``pathname``, using password string ``password``.
  ## The index successful decryptions is returned
  var data: JsonNode
  var decodedKeyfile: KfResult[seq[byte]]
  var successfullyDecodedKeyfiles: seq[KfResult[seq[byte]]]

  if fileExists(pathname) == false:
    return err(KeyfileDoesNotExist)

  # Note that lines strips the ending newline, if present
  try:
    for keyfile in lines(pathname):
      # We skip empty lines
      if keyfile.len == 0:
        continue
      # We skip all lines that doesn't seem to define a json
      if keyfile[0] != '{' or keyfile[^1] != '}':
        continue

      try:
        data = json.parseJson(keyfile)
      except JsonParsingError:
        return err(KeyfileJsonError)
      except ValueError:
        return err(KeyfileJsonError)
      except OSError:
        return err(KeyfileOsError)
      except Exception: #parseJson raises Exception
        return err(KeyfileOsError)

      decodedKeyfile = decodeKeyFileJson(data, password)
      if decodedKeyfile.isOk():
        successfullyDecodedKeyfiles.add decodedKeyfile
  except IOError:
    return err(KeyfileIoError)

  return ok(successfullyDecodedKeyfiles)

# Note that the keyfile is open in Append mode so that multiple credentials can be stored in same file
proc saveKeyFile*(pathname: string, jobject: JsonNode): KfResult[void] =
  ## Save JSON object ``jobject`` to file with pathname ``pathname``.
  var f: File
  if not f.open(pathname, fmAppend):
    return err(KeyfileOsError)
  try:
    # To avoid other users/attackers to be able to read keyfiles, we make the file readable/writable only by the running user
    setFilePermissions(pathname, {fpUserWrite, fpUserRead})
    f.write($jobject)
    # We store a keyfile per line
    f.write("\n")
    ok()
  except CatchableError:
    err(KeyfileOsError)
  finally:
    f.close()
