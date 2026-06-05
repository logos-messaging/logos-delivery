## Waku content topics definition and namespacing utils
##
## See 23/WAKU2-TOPICS RFC: https://rfc.vac.dev/spec/23/

{.push raises: [].}

import std/options, std/strutils, results
import ./parsing

export parsing

## Content topic

type ContentTopic* = string

const DefaultContentTopic* = ContentTopic("/waku/2/default-content/proto")

## Namespaced content topic

type NsContentTopic* = object
  generation*: Option[int]
  application*: string
  version*: string
  name*: string
  encoding*: string

proc init*(
    T: type NsContentTopic,
    generation: Option[int],
    application: string,
    version: string,
    name: string,
    encoding: string,
): T =
  NsContentTopic(
    generation: generation,
    application: application,
    version: version,
    name: name,
    encoding: encoding,
  )

# Serialization

proc `$`*(topic: NsContentTopic): string =
  ## Returns a string representation of a namespaced topic
  ## in the format `/<application>/<version>/<topic-name>/<encoding>`
  ## Autosharding adds 1 optional prefix `/<gen#>

  var formatted = ""

  if topic.generation.isSome():
    formatted = formatted & "/" & $topic.generation.get()

  formatted & "/" & topic.application & "/" & topic.version & "/" & topic.name & "/" &
    topic.encoding

# Deserialization

proc parse*(
    T: type NsContentTopic, topic: ContentTopic | string
): ParsingResult[NsContentTopic] =
  ## Splits a namespaced topic string into its constituent parts.
  ## The topic string has to be in the format `/<application>/<version>/<topic-name>/<encoding>`
  ## Autosharding adds 1 optional prefix `/<gen#>

  if not topic.startsWith("/"):
    return err(
      ParsingError.invalidFormat("content-topic '" & topic & "' must start with slash")
    )

  let parts = topic[1 ..< topic.len].split("/")

  case parts.len
  of 4:
    let app = parts[0]
    if app.len == 0:
      return err(ParsingError.missingPart("application"))

    let ver = parts[1]
    if ver.len == 0:
      return err(ParsingError.missingPart("version"))

    let name = parts[2]
    if name.len == 0:
      return err(ParsingError.missingPart("topic-name"))

    let enc = parts[3]
    if enc.len == 0:
      return err(ParsingError.missingPart("encoding"))

    return ok(NsContentTopic.init(none(int), app, ver, name, enc))
  of 5:
    if parts[0].len == 0:
      return err(ParsingError.missingPart("generation"))

    let gen =
      try:
        parseInt(parts[0])
      except ValueError:
        return err(ParsingError.invalidFormat("generation should be a numeric value"))

    let app = parts[1]
    if app.len == 0:
      return err(ParsingError.missingPart("application"))

    let ver = parts[2]
    if ver.len == 0:
      return err(ParsingError.missingPart("version"))

    let name = parts[3]
    if name.len == 0:
      return err(ParsingError.missingPart("topic-name"))

    let enc = parts[4]
    if enc.len == 0:
      return err(ParsingError.missingPart("encoding"))

    return ok(NsContentTopic.init(some(gen), app, ver, name, enc))
  else:
    let errMsg =
      "Invalid content topic structure. Expected either /<application>/<version>/<topic-name>/<encoding> or /<gen>/<application>/<version>/<topic-name>/<encoding>"
    return err(ParsingError.invalidFormat(errMsg))

proc parse*(
    T: type NsContentTopic, topics: seq[ContentTopic]
): ParsingResult[seq[NsContentTopic]] =
  var res: seq[NsContentTopic] = @[]
  for contentTopic in topics:
    let parseRes = NsContentTopic.parse(contentTopic).valueOr:
      let pError: ParsingError = error
      return ParsingResult[seq[NsContentTopic]].err(pError)
    res.add(parseRes)
  return ParsingResult[seq[NsContentTopic]].ok(res)

# Content topic compatibility

converter toContentTopic*(topic: NsContentTopic): ContentTopic =
  $topic
