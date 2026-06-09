import std/strutils, regex, results

proc validateDbUrl*(dbUrl: string): Result[string, string] =
  ## dbUrl mimics SQLAlchemy Database URL schema
  ## See: https://docs.sqlalchemy.org/en/14/core/engines.html#database-urls
  let regex = re2"^\w+:\/\/.+:.+@[\w*-.]+:[0-9]+\/[\w*-.]+$"
  let dbUrl = dbUrl.strip()
  if "sqlite" in dbUrl or dbUrl == "" or dbUrl == "none" or dbUrl.match(regex):
    return ok(dbUrl)
  else:
    return err("invalid 'db url' option format")

proc getDbEngine*(dbUrl: string): Result[string, string] =
  let dbUrlParts = dbUrl.split("://", 1)

  if dbUrlParts.len != 2:
    return err("Incorrect dbUrl")

  let engine = dbUrlParts[0]
  return ok(engine)

proc getDbPath*(dbUrl: string): Result[string, string] =
  let dbUrlParts = dbUrl.split("://", 1)

  if dbUrlParts.len != 2:
    return err("Incorrect dbUrl")

  let path = dbUrlParts[1]
  return ok(path)
