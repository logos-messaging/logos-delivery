# master vs refactor/kernel-single-file: structure metrics

Folder-level import graph of `logos_delivery/` (Nim `import`/`export`/`include`, relative and
`logos_delivery/...` paths). A folder is a first-level directory of `waku/` (master) or
`kernel/` (branch), plus `api`, `channels`, `messaging`. Root files of `waku/` belong to
their protocol folder when one exists (`waku_core.nim` -> `waku_core/`), otherwise they are
their own node (`kernel/kernel.nim`, `kernel/metrics_server.nim`). Imports inside one folder
are ignored. Measured on `origin/master` and `origin/refactor/kernel-single-file`.

| Metric | master | kernel-single-file |
|---|---:|---:|
| `.nim` files under `logos_delivery/` | 329 | 282 |
| Folders (nodes in the graph) | 32 | 19 |
| Kernel folders | 28 | 15 |
| Folder-to-folder imports | 175 | 94 |
| Import cycles (strongly connected sets) | 1 | 0 |
| Folders inside a cycle | 27 of 32 | 0 of 19 |
| Imports against layering (upper bound, see below) | 29 | 0 |
| Kernel imports of top-level `api/` | 10 | 2 |
| Max folder fan-out | 21 (`node`) | 15 (`kernel/api`) |
| Max folder fan-in | 24 (`waku_core`) | 17 (`kernel/base`) |
| Largest folder (files) | 31 (`node`) | 60 (`protocols`) |

Against-layering imports: folders are ordered bottom-up by repeatedly peeling folders with no
remaining dependencies; when a cycle blocks that, the folder with the fewest remaining
dependencies goes next. Imports pointing to a later folder are counted. It is a heuristic
upper bound on the minimum number of back edges, not the exact minimum.

Not in the numbers: `protocols/` has 60 files, so the folder reduction partly moved
complexity inside folders. Merging folders also removes cross-folder imports by definition;
the cycle result does not depend on that.

The matrices are in `dsm-master-vs-kernel.svg`.
