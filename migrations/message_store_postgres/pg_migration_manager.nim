import
  content_script_version_1, content_script_version_2, content_script_version_3,
  content_script_version_4, content_script_version_5, content_script_version_6,
  content_script_version_7

type MigrationScript* = object
  version*: int
  scriptContent*: string

proc init*(T: type MigrationScript, targetVersion: int, scriptContent: string): T =
  return MigrationScript(targetVersion: targetVersion, scriptContent: scriptContent)

const PgMigrationScripts* = @[
  MigrationScript(version: 1, scriptContent: ContentScriptVersion_1),
  MigrationScript(version: 2, scriptContent: ContentScriptVersion_2),
  MigrationScript(version: 3, scriptContent: ContentScriptVersion_3),
  MigrationScript(version: 4, scriptContent: ContentScriptVersion_4),
  MigrationScript(version: 5, scriptContent: ContentScriptVersion_5),
  MigrationScript(version: 6, scriptContent: ContentScriptVersion_6),
  MigrationScript(version: 7, scriptContent: ContentScriptVersion_7),
]

proc getMigrationScripts*(currentVersion: int64, targetVersion: int64): seq[string] =
  var ret = newSeq[string]()
  var v = currentVersion
  while v < targetVersion:
    ret.add(PgMigrationScripts[v].scriptContent)
    v.inc()
  return ret
