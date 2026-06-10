{.push raises: [].}

proc flatten*[T](a: seq[seq[T]]): seq[T] =
  var aFlat = newSeq[T](0)
  for subseq in a:
    aFlat &= subseq
  return aFlat
