{.push raises: [].}

import options, json, strutils, sequtils, std/[tables, os]

import ./keyfile, ./conversion_utils, ./protocol_types, ./utils

# This proc creates an empty keystore (i.e. with no credentials)
proc createAppKeystore*(
    path: string, appInfo: AppInfo, separator: string = "\n"
): KeystoreResult[void] =
  let keystore = AppKeystore(
    application: appInfo.application,
    appIdentifier: appInfo.appIdentifier,
    version: appInfo.version,
    credentials: initTable[string, KeystoreMembership](),
  )

  var jsonKeystore: string
  jsonKeystore.toUgly(%keystore)

  var f: File
  if not f.open(path, fmWrite):
    return
      err(AppKeystoreError(kind: KeystoreOsError, msg: "Cannot open file for writing"))

  try:
    # To avoid other users/attackers to be able to read keyfiles, we make the file readable/writable only by the running user
    setFilePermissions(path, {fpUserWrite, fpUserRead})
    f.write(jsonKeystore)
    # We separate keystores with separator
    f.write(separator)
    ok()
  except CatchableError:
    err(
      AppKeystoreError(
        kind: KeystoreOsError,
        msg: "error while writing keystore: " & getCurrentExceptionMsg(),
      )
    )
  finally:
    f.close()

# This proc load a keystore based on the application, appIdentifier and version filters.
# If none is found, it automatically creates an empty keystore for the passed parameters
proc loadAppKeystore*(
    path: string, appInfo: AppInfo, separator: string = "\n"
): KeystoreResult[JsonNode] =
  ## Load and decode JSON keystore from pathname
  var data: JsonNode

  # If no keystore exists at path we create a new empty one with passed keystore parameters
  if fileExists(path) == false:
    ?createAppKeystore(path, appInfo, separator)

  try:
    # We read all the file contents
    var f: File
    if not f.open(path, fmRead):
      return err(
        AppKeystoreError(kind: KeystoreOsError, msg: "Cannot open file for reading")
      )

    ## the next blocks expect the whole keystore.json content to be compacted in one single line
    let fileContents = readAll(f).replace(" ", "").replace("\n", "")

    # We iterate over each substring split by separator (which we expect to correspond to a single keystore json)
    for keystore in fileContents.split(separator):
      # We skip if read line is empty
      if keystore.len == 0:
        continue
      # We skip all lines that don't seem to define a json
      if not keystore.startsWith("{") or not keystore.endsWith("}"):
        continue

      try:
        # We parse the json
        data = json.parseJson(keystore)

        # We check if parsed json contains the relevant keystore credentials fields and if these are set to the passed parameters
        # (note that "if" is lazy, so if one of the .contains() fails, the json fields contents will not be checked and no ResultDefect will be raised due to accessing unavailable fields)
        if not data.hasKeys(["application", "appIdentifier", "credentials", "version"]):
          return err(
            AppKeystoreError(
              kind: KeystoreJsonKeyError, msg: "Missing required fields in keystore"
            )
          )

        if data["application"].getStr() != appInfo.application:
          return err(
            AppKeystoreError(
              kind: KeystoreJsonValueMismatchError,
              msg:
                "Application does not match. Expected '" & appInfo.application &
                "' but got '" & data["application"].getStr() & "'",
            )
          )

        if data["appIdentifier"].getStr() != appInfo.appIdentifier:
          return err(
            AppKeystoreError(
              kind: KeystoreJsonValueMismatchError,
              msg:
                "AppIdentifier does not match. Expected '" & appInfo.appIdentifier &
                "' but got '" & data["appIdentifier"].getStr() & "'",
            )
          )

        if data["version"].getStr() != appInfo.version:
          return err(
            AppKeystoreError(
              kind: KeystoreJsonValueMismatchError,
              msg:
                "Version does not match. Expected '" & appInfo.version & "' but got '" &
                data["version"].getStr() & "'",
            )
          )
          # We return the first json keystore that matches the passed app parameters
          # We assume a unique kesytore with such parameters is present in the file
        return ok(data)
      # TODO: we might continue rather than return for some of these errors
      except JsonParsingError:
        return err(
          AppKeystoreError(
            kind: KeystoreJsonError,
            msg:
              "error during loading keystore, JsonParsingError: " &
              getCurrentExceptionMsg(),
          )
        )
      except ValueError:
        return err(
          AppKeystoreError(
            kind: KeystoreJsonError,
            msg:
              "error during loading keystore, ValueError: " & getCurrentExceptionMsg(),
          )
        )
      except OSError:
        return err(
          AppKeystoreError(
            kind: KeystoreOsError,
            msg: "error during loading keystore, OSError: " & getCurrentExceptionMsg(),
          )
        )
      except Exception: #parseJson raises Exception
        return err(
          AppKeystoreError(
            kind: KeystoreOsError,
            msg: "error during loading keystore, Exception: " & getCurrentExceptionMsg(),
          )
        )
  except IOError:
    return err(
      AppKeystoreError(
        kind: KeystoreIoError,
        msg: "error during loading keystore, IOError: " & getCurrentExceptionMsg(),
      )
    )

  return err(
    AppKeystoreError(
      kind: KeystoreKeystoreDoesNotExist, msg: "The keystore file could not be parsed"
    )
  )

# Adds a membership credential to the keystore matching the application, appIdentifier and version filters.
proc addMembershipCredentials*(
    path: string,
    membership: KeystoreMembership,
    password: string,
    appInfo: AppInfo,
    separator: string = "\n",
): KeystoreResult[void] =
  # We load the keystore corresponding to the desired parameters
  # This call ensures that JSON has all required fields

  # We load the JSON node corresponding to the app keystore
  let jsonKeystore = ?loadAppKeystore(path, appInfo, separator)

  try:
    if jsonKeystore.hasKey("credentials"):
      # We get all credentials in keystore
      let keystoreCredentials = jsonKeystore["credentials"]
      let key = membership.hash()
      if keystoreCredentials.hasKey(key):
        # noop
        return ok()

      let encodedMembershipCredential = membership.encode()
      # We add it to the credentials field of the keystore
      jsonKeystore["credentials"][key] = createKeyFileJson(
        encodedMembershipCredential, password
      ).valueOr:
        return err(AppKeystoreError(kind: KeystoreCreateKeyfileError, msg: $error))
  except CatchableError:
    return err(AppKeystoreError(kind: KeystoreJsonError, msg: getCurrentExceptionMsg()))

  # We save to disk the (updated) keystore.
  ?save(jsonKeystore, path, separator)

  return ok()

# Returns the membership credentials in the keystore matching the application, appIdentifier and version filters, further filtered by the input
# identity credentials and membership contracts
proc getMembershipCredentials*(
    path: string, password: string, query: KeystoreMembership, appInfo: AppInfo
): KeystoreResult[KeystoreMembership] =
  # We load the keystore corresponding to the desired parameters
  # This call ensures that JSON has all required fields

  # We load the JSON node corresponding to the app keystore
  let jsonKeystore = ?loadAppKeystore(path, appInfo)

  try:
    if jsonKeystore.hasKey("credentials"):
      # We get all credentials in keystore
      var keystoreCredentials = jsonKeystore["credentials"]
      if keystoreCredentials.len == 0:
        # error
        return err(
          AppKeystoreError(
            kind: KeystoreCredentialNotFoundError,
            msg: "No credentials found in keystore",
          )
        )
      var keystoreCredential: JsonNode
      if keystoreCredentials.len == 1:
        keystoreCredential = keystoreCredentials.getFields().values().toSeq()[0]
      else:
        let key = query.hash()
        if not keystoreCredentials.hasKey(key):
          # error
          return err(
            AppKeystoreError(
              kind: KeystoreCredentialNotFoundError,
              msg:
                "Credential not found in keystore. There are multiple credentials in this keystore, please check if you have used the correct parameters.",
            )
          )
        keystoreCredential = keystoreCredentials[key]

      let decodedKeyfile = decodeKeyFileJson(keystoreCredential, password).valueOr:
        return err(AppKeystoreError(kind: KeystoreReadKeyfileError, msg: $error))
      # we parse the json decrypted keystoreCredential
      let decodedCredentialRes = decode(decodedKeyfile)
      let keyfileMembershipCredential = decodedCredentialRes.get()
      return ok(keyfileMembershipCredential)
  except CatchableError:
    return err(AppKeystoreError(kind: KeystoreJsonError, msg: getCurrentExceptionMsg()))
