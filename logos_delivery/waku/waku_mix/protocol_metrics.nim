{.push raises: [].}

import metrics

declarePublicCounter logos_delivery_mix_bootnode_resolve_failures,
  "mix bootstrap entries dropped: a malformed multiaddress, a name with no resolver, a lookup that failed, timed out or answered with nothing, or a name that resolved only to further names"
