## Unicode-aware identifier casing and doc-comment rendering, shared by codegen
## and the FFI macro.

import std/[strutils, unicode]

func docLines(doc: string): seq[string] =
  ## `doc` split into lines, trailing blank ones dropped.
  if doc.strip().len == 0:
    return @[]
  var lines = doc.splitLines()
  while lines.len > 0 and lines[^1].strip().len == 0:
    lines.setLen(lines.len - 1)
  return lines

func renderDocComment*(doc, indent, prefix: string): seq[string] =
  ## `doc` as one `prefix`-led line comment per source line, at `indent`.
  var rendered: seq[string] = @[]
  for line in docLines(doc):
    # A trailing `\` would splice the next generated line into a `//` comment.
    rendered.add(
      indent & (prefix & line).strip(leading = false, chars = Whitespace + {'\\'})
    )
  return rendered

func renderMemberDocComment*(doc: string): seq[string] =
  ## `///` at the indent C++ class members and Rust `impl` items sit at.
  return doc.renderDocComment("    ", "/// ")

func escapeBlockComment(line: string): string =
  ## `*/` would close the comment early and splice the rest in as code.
  return line.replace("*/", "* /")

func renderBlockDocComment*(doc: string, indent = ""): seq[string] =
  ## `doc` as a `/** ... */` block at `indent`; one-liners stay on one line.
  let lines = docLines(doc)
  if lines.len == 0:
    return @[]
  if lines.len == 1:
    return @[indent & "/** " & escapeBlockComment(lines[0].strip()) & " */"]
  var rendered = @[indent & "/**"]
  for line in lines:
    rendered.add((indent & " * " & escapeBlockComment(line)).strip(leading = false))
  rendered.add(indent & " */")
  return rendered

proc toLower*(s: string): string =
  ## Unicode-aware lowercase for an entire string.
  var buf = ""
  for r in runes(s):
    buf.add($r.toLower())
  return buf

proc camelToSnakeCase*(s: string): string =
  ## camelCase → snake_case, e.g. "delayMs" → "delay_ms".
  var snake = ""
  var first = true
  for r in runes(s):
    if r.isUpper() and not first:
      snake.add('_')
    snake.add($r.toLower())
    first = false
  return snake

func capitalizeFirstLetter*(s: string): string =
  ## Returns `s` with its first rune uppercased, rest unchanged.
  if s.len == 0:
    return s
  var runesSeq = toRunes(s)
  runesSeq[0] = runesSeq[0].toUpper()
  return $runesSeq

func identToUpperSnake*(s: string): string =
  ## Nim identifier → UPPER_SNAKE, keeping acronym runs intact: "maxPeers" and
  ## "MAX_PEERS" both give "MAX_PEERS", "httpTTL" gives "HTTP_TTL".
  var upper = ""
  let rs = toRunes(s)
  for i, r in rs:
    if r == Rune('_'):
      if upper.len > 0 and upper[^1] != '_':
        upper.add('_')
      continue
    let startsWord =
      i > 0 and r.isUpper() and
      (not rs[i - 1].isUpper() or (i + 1 < rs.len and rs[i + 1].isLower()))
    if startsWord and upper.len > 0 and upper[^1] != '_':
      upper.add('_')
    upper.add($r.toUpper())
  return upper

proc snakeToPascalCase*(s: string): string =
  ## snake_case → PascalCase, e.g. "hello_world" → "HelloWorld".
  let parts = s.split('_')
  var pascal = ""
  for p in parts:
    pascal.add capitalizeFirstLetter(p)
  return pascal
