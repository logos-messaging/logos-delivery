{.push raises: [].}

type
  HexDataStr* = distinct string
  Identifier* = distinct string # 32 bytes, no 0x prefix!
  HexStrings* = HexDataStr | Identifier

# Validation

template hasHexHeader(value: string): bool =
  if value.len >= 2 and value[0] == '0' and value[1] in {'x', 'X'}: true else: false

template isHexChar(c: char): bool =
  if c notin {'0' .. '9'} and c notin {'a' .. 'f'} and c notin {'A' .. 'F'}:
    false
  else:
    true

func isValidHexQuantity*(value: string): bool =
  if not hasHexHeader(value):
    return false

  # No leading zeros (but allow 0x0)
  if value.len < 3 or (value.len > 3 and value[2] == '0'):
    return false

  for i in 2 ..< value.len:
    let c = value[i]
    if not isHexChar(c):
      return false

  return true

func isValidHexData*(value: string, header = true): bool =
  if header and not hasHexHeader(value):
    return false

  # Must be even number of digits
  if value.len mod 2 != 0:
    return false

  # Leading zeros are allowed
  for i in 2 ..< value.len:
    let c = value[i]
    if not isHexChar(c):
      return false

  return true

template isValidHexData*(value: string, hexLen: int, header = true): bool =
  value.len == hexLen and value.isValidHexData(header)

proc validateHexData*(value: string) {.inline, raises: [ValueError].} =
  if unlikely(not isValidHexData(value)):
    raise newException(ValueError, "Invalid hex data format: " & value)

# Initialisation

proc hexDataStr*(value: string): HexDataStr {.inline, raises: [ValueError].} =
  validateHexData(value)
  HexDataStr(value)
