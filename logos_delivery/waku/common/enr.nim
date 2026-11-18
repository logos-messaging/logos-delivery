## An extension wrapper around nim-eth's ENR module

import eth/p2p/discoveryv5/enr
import ./enr/builder, ./enr/typed_record

# `fromBase64` and `fromURI` are exported for their Result overloads; nim-eth
# keeps deprecated `var Record` overloads under the same names.
{.push warning[Deprecated]: off.}
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
{.pop.}
