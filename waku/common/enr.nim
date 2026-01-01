## An extension wrapper around nim-eth's ENR module

import eth/enr/enr
import ./enr/builder, ./enr/typed_record

export
  enr.Record,
  enr.EnrResult,
  enr.get,
  enr.tryGet,
  enr.fromBase64,
  enr.toBase64,
  enr.fromURI,
  enr.toURI,
  enr.FieldPair,
  enr.toFieldPair,
  enr.init, # TODO: Delete after removing the deprecated procs
  builder,
  typed_record
