import results, std/options, typetraits, tables, os, serialization, ./utils

type EnvvarWriter* = object
  prefix: string
  key: seq[string]

proc init*(T: type EnvvarWriter, prefix: string): T =
  result.prefix = prefix

proc writeValue*(w: var EnvvarWriter, value: auto) =
  mixin enumInstanceSerializedFields, writeValue, writeFieldIMPL
  # TODO: reduce allocation

  when value is string:
    let key = constructKey(w.prefix, w.key)
    os.putEnv(key, value)
  elif value is (SomePrimitives or range):
    let key = constructKey(w.prefix, w.key)
    setValue(key, value)
  elif value is Opt:
    if value.isSome:
      w.writeValue value.get
  elif value is Option:
    if value.isSome:
      w.writeValue value.get
  elif value is (seq or array or openArray):
    when uTypeIsPrimitives(type value):
      let key = constructKey(w.prefix, w.key)
      setValue(key, value)
    elif uTypeIsRecord(type value):
      let key = w.key[^1]
      for i in 0 ..< value.len:
        w.key[^1] = key & $i
        w.writeValue(value[i])
    else:
      const typeName = typetraits.name(value.type)
      {.fatal: "Failed to convert to Envvar array an unsupported type: " & typeName.}
  elif value is (object or tuple):
    type RecordType = type value
    w.key.add ""
    value.enumInstanceSerializedFields(fieldName, field):
      w.key[^1] = fieldName
      w.writeFieldIMPL(FieldTag[RecordType, fieldName], field, value)
    discard w.key.pop()
  else:
    const typeName = typetraits.name(value.type)
    {.fatal: "Failed to convert to Envvar an unsupported type: " & typeName.}
