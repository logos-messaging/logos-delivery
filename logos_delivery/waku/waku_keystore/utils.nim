{.push raises: [].}

import json, std/[os, sequtils]

import ./keyfile, ./protocol_types

# Checks if a JsonNode has all keys contained in "keys"
proc hasKeys*(data: JsonNode, keys: openArray[string]): bool =
  return all(
    keys,
    proc(key: string): bool =
      return data.hasKey(key),
  )

# Safely saves a Keystore's JsonNode to disk.
# If exists, the destination file is renamed with extension .bkp; the file is written at its destination and the .bkp file is removed if write is successful, otherwise is restored
proc save*(json: JsonNode, path: string, separator: string): KeystoreResult[void] =
  # We first backup the current keystore
  if fileExists(path):
    try:
      moveFile(path, path & ".bkp")
    except: # TODO: Fix "BareExcept" warning
      return err(
        AppKeystoreError(
          kind: KeystoreOsError,
          msg: "could not backup keystore: " & getCurrentExceptionMsg(),
        )
      )

  # We save the updated json
  var f: File
  if not f.open(path, fmAppend):
    return err(
      AppKeystoreError(
        kind: KeystoreOsError,
        msg: "error in waku_keystore save: " & getCurrentExceptionMsg(),
      )
    )
  try:
    # To avoid other users/attackers to be able to read keyfiles, we make the file readable/writable only by the running user
    setFilePermissions(path, {fpUserWrite, fpUserRead})
    f.write($json)
    # We store a keyfile per line
    f.write(separator)
  except CatchableError:
    # We got some KeystoreOsError writing to disk. We attempt to restore the previous keystore backup
    if fileExists(path & ".bkp"):
      try:
        f.close()
        removeFile(path)
        moveFile(path & ".bkp", path)
      except: # TODO: Fix "BareExcept" warning
        # Unlucky, we just fail
        return err(
          AppKeystoreError(
            kind: KeystoreOsError,
            msg: "could not restore keystore backup: " & getCurrentExceptionMsg(),
          )
        )
    return err(
      AppKeystoreError(
        kind: KeystoreOsError,
        msg: "could not write keystore: " & getCurrentExceptionMsg(),
      )
    )
  finally:
    f.close()

  # The write went fine, so we can remove the backup keystore
  if fileExists(path & ".bkp"):
    try:
      removeFile(path & ".bkp")
    except CatchableError:
      return err(
        AppKeystoreError(
          kind: KeystoreOsError,
          msg: "could not remove keystore backup: " & getCurrentExceptionMsg(),
        )
      )

  return ok()
