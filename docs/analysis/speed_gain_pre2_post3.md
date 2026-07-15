# Speed gain: pre-phase-2 vs post-phase-3 (same-session A/B)

Rigorous before/after of the no-copy refactor chain, both branches built and run
**back-to-back on the same machine, in the same session**, with identical build
flags and an identical (temporary, uncommitted) GC-sampling patch to
`apps/benchmarks/message_path_bench.nim`.

## Methodology

| Item | Value |
|---|---|
| Branch A ("pre-phase-2") | `experimental/chore-nocopy-e2e-perf-harness` @ `2a4da679` |
| Branch B ("post-phase-3") | `experimental/chore-nocopy-wakuenvelop` @ `a6f1065a` |
| Machine / OS | Apple M4, macOS (arm64) |
| Nim | 2.2.4, `--mm:refc` |
| Build flags (both) | `--mm:refc --cpu:arm64 --passC:"-arch arm64" --passL:"-arch arm64" -d:msgPathCounters -d:chronicles_log_level=ERROR --passL:librln_v2.0.2.a --passL:-lm` (copied from the `benchMessagePath` nimble task) |
| Workload (both) | seed 42, payload mix 10/50/150 kB @ 25/50/25 %, N=1000 measured + 100 warmup |
| Run order | A built+run (2 passes) → B built+run (3 passes; B pass 1 discarded, micro variance 5.51 % under a load spike to 13.8) |
| Machine load | A passes: load avg ~3.3. B passes: elevated (8.9–13.8) — noted; the two accepted B passes have micro variance 3.34 % / 4.15 % (< 5 %). |

**Sampling design (temporary patch, identical on both branches — only the relay
handler signature differs between branches, which the sampling code does not
touch):**
- Micro loop and macro receive loop: every 50 messages record
  `(msg_index, getOccupiedMem(), getTotalMem())` into a pre-allocated buffer
  (no per-sample heap churn).
- End of each scenario: `getMaxMem()` (process peak heap — the key single
  number) and `GC_getStatistics()`.
- Existing `gc_collections` counter retained.
- All raw outputs saved outside the repo; the patch was `git checkout --`
  discarded before switching branches (verified clean each time).

The instrumented builds are byte-identical in decode/hash counters to the
committed `bench_baseline.md` numbers, confirming the patch did not perturb the
measured path.

## Throughput — pre vs post

Micro = single-node isolated receiver path; macro = two loopback nodes,
publisher + archiving receiver. Micro msg/s is the mean of all accepted
micro runs (A: 4 values across 2 passes; B: 4 values across 2 passes).

| Scenario | Metric | Pre (A) | Post (B) | Gain |
|---|---|---|---|---|
| micro | msg/s (mean) | 1222.8 | 2273.7 | **+85.9 %** |
| micro | ns/msg p50 | ~630 k | ~338 k | −46 % |
| micro | ns/msg p99 | ~1.94 M | ~1.09 M | −44 % |
| micro | decodes/msg | 2.000 | 2.000 | unchanged |
| micro | hashes/msg | 2.000 | **1.000** | −50 % |
| micro | hashed_MB | 130.00 | **65.00** | −50 % |
| macro | msg/s (mean) | 225.45 | 353.1 | **+56.6 %** |
| macro | ns/msg p50 | ~3.55 M | ~2.29 M | −36 % |
| macro | ns/msg p99 | ~10.7 M | ~7.5 M | −30 % |
| macro | decodes/msg | 6.000 | **3.000** | −50 % |
| macro | hashes/msg | 5.000 | **3.000** | −40 % |
| macro | decoded_MB / hashed_MB | 390.33 / 325.00 | **195.16 / 195.00** | ~−50 % |

Raw CSV rows (accepted passes):

```
# A (pre-phase-2) — pass 1 / pass 2
micro_run1,1000,834.793ms,1197.9,p50=640000,p99=1980291,dec=2.000,hash=2.000
micro_run2,1000,803.157ms,1245.1,p50=618708,p99=1928250,dec=2.000,hash=2.000
micro_run1,1000,835.163ms,1197.4,p50=642250,p99=1939583,dec=2.000,hash=2.000
micro_run2,1000,799.486ms,1250.8,p50=621750,p99=1866667,dec=2.000,hash=2.000
macro,1000,4431.571ms,225.7,p50=3552333,p99=10703625,dec=6.000,hash=5.000
macro,1000,4441.265ms,225.2,p50=3580583,p99=10964584,dec=6.000,hash=5.000
# B (post-phase-3) — pass 2 / pass 3 (pass 1 discarded, variance>5% under load)
micro_run1,1000,451.768ms,2213.5,p50=345792,p99=1138042,dec=2.000,hash=1.000
micro_run2,1000,436.666ms,2290.1,p50=335709,p99=1045417,dec=2.000,hash=1.000
micro_run1,1000,445.048ms,2246.9,p50=340917,p99=1092750,dec=2.000,hash=1.000
micro_run2,1000,426.569ms,2344.3,p50=329458,p99=1062291,dec=2.000,hash=1.000
macro,1000,2884.679ms,353.0(pass2 353.0),p50=2276292,p99=7292208,dec=3.000,hash=3.000
macro,1000,2831.619ms,353.2,p50=2304750,p99=8211292,dec=3.000,hash=3.000
```

The throughput win is driven by the removed redundant decodes/hashes (byte
volumes halved), not by memory effects.

## GC / heap analysis

### Peak heap (`getMaxMem`, process-monotonic)

| Scenario | Pre (A) | Post (B) | Δ |
|---|---|---|---|
| micro (first scenario, cleanest) | 333.60 MB | 263.61 MB | **−21.0 %** |
| macro (whole-process peak) | 514.86 MB | 408.40 MB | **−20.7 %** |

`gc_collections` (from `GC_getStatistics`): micro 7 / 8, macro 10 — **identical
on both branches**. Same number of GC cycles; the new code simply sits at a
lower occupied level at every point.

### Heap-elevation series (occupied / total, MB)

**Micro — no retention.** Occupied oscillates around a *flat* mean; `getTotalMem`
(reserved arena) is dead-flat for the entire loop on both branches. There is **no
elevation slope** in either — the transient decode/hash temporaries are allocated
and freed between the 50-msg samples and the refc arena is reused in place.

| msg idx | A occ | A total | B occ | B total |
|---|---|---|---|---|
| 0   | 275.50 | 333.60 | 207.07 | 263.61 |
| 200 | 275.41 | 333.60 | 211.45 | 263.61 |
| 400 | 274.67 | 333.60 | 208.16 | 263.61 |
| 600 | 275.43 | 333.60 | 217.90 | 263.61 |
| 800 | 274.36 | 333.60 | 208.91 | 263.61 |
| 950 | 275.37 | 333.60 | 215.19 | 263.61 |

- A occupied range 273.5–275.7 MB → **sawtooth amplitude ≈ 2.2 MB**.
- B occupied range 207.1–217.9 MB → **sawtooth amplitude ≈ 10.8 MB**.
- Both slopes ≈ 0 MB/100msg. Reserved total constant throughout.

**Macro — archive retains all 1000 messages.** Occupied climbs monotonically
(this is *retention*, the archive `SortedSet` accumulating messages), not
transient churn.

| msg idx | A occ | A total | B occ | B total |
|---|---|---|---|---|
| 50   | 308.66 | 414.61 | 235.78 | 329.06 |
| 200  | 321.78 | 414.62 | 256.83 | 329.06 |
| 400  | 353.13 | 414.64 | 283.56 | 329.07 |
| 600  | 378.20 | 414.66 | 315.62 | 408.36 |
| 800  | 405.33 | 414.85 | 336.89 | 408.38 |
| 1000 | 428.25 | 514.86 | 361.54 | 408.40 |

- Retention slope: A ≈ **12.6 MB / 100 msg**, B ≈ **13.2 MB / 100 msg** —
  statistically identical (same 1000 messages retained; payload bytes are
  retained identically under value vs ref semantics).
- Reserved-arena growth: exactly **one** step each — A 414.6→514.8 MB at msg
  ~650; B 329.1→408.4 MB at msg ~600.
- The new code runs a **constant ~65–75 MB lower** at every sample and peaks
  20.7 % lower.

<details><summary>Full CSV series (every 50 msgs; MB)</summary>

```
# scenario=micro_run1  branch=A(pre-2)  idx,occMB,totMB
0,275.50,333.60
50,275.40,333.60
100,273.50,333.60
150,273.95,333.60
200,275.41,333.60
250,275.43,333.60
300,275.41,333.60
350,273.58,333.60
400,274.67,333.60
450,273.52,333.60
500,275.41,333.60
550,274.95,333.60
600,275.43,333.60
650,275.16,333.60
700,275.43,333.60
750,274.01,333.60
800,274.36,333.60
850,273.54,333.60
900,275.70,333.60
950,275.37,333.60
# scenario=macro  branch=A(pre-2)  idx,occMB,totMB
50,308.66,414.61
100,313.30,414.61
150,315.54,414.62
200,321.78,414.62
250,330.46,414.63
300,345.20,414.63
350,346.85,414.63
400,353.13,414.64
450,362.43,414.64
500,376.96,414.65
550,383.31,414.65
600,378.20,414.66
650,385.16,514.83
700,395.89,514.84
750,398.69,514.84
800,405.33,514.85
850,412.23,514.85
900,423.95,514.85
950,425.55,514.86
1000,428.25,514.86
# scenario=micro_run1  branch=B(post-3)  idx,occMB,totMB
0,207.07,263.61
50,215.58,263.61
100,209.58,263.61
150,215.05,263.61
200,211.45,263.61
250,207.21,263.61
300,217.89,263.61
350,211.46,263.61
400,208.16,263.61
450,212.43,263.61
500,215.31,263.61
550,210.43,263.61
600,217.90,263.61
650,211.09,263.61
700,212.69,263.61
750,213.75,263.61
800,208.91,263.61
850,207.23,263.61
900,214.70,263.61
950,215.19,263.61
# scenario=macro  branch=B(post-3)  idx,occMB,totMB
50,235.78,329.06
100,247.91,329.06
150,250.84,329.06
200,256.83,329.06
250,261.66,329.06
300,268.57,329.06
350,277.31,329.07
400,283.56,329.07
450,290.08,329.08
500,303.78,329.08
550,306.02,329.08
600,315.62,408.36
650,315.92,408.37
700,333.08,408.38
750,330.20,408.38
800,336.89,408.38
850,346.05,408.39
900,354.25,408.39
950,359.48,408.40
1000,361.54,408.40
```
</details>

## Verdict on the hypothesis

> Hypothesis: retained memory ~flat (temporary copies dominate), but the OLD
> code shows a *faster heap-allocation elevation pattern* (steeper growth /
> higher sawtooth amplitude / higher peak) than the new code.

**(a) Retained memory flat? — CONFIRMED (as a between-version statement).**
In micro there is no retention and occupied is flat on both branches. In macro
the retention *slope* is essentially identical pre vs post (~12.6 vs ~13.2
MB/100 msg) because the same 1000 messages are retained regardless of value-vs-
ref semantics. Retained growth is a function of the workload, not the refactor.

**(b) Allocation-elevation *slower* after the refactor? — NOT SUPPORTED by this
instrumentation.** The occupied/total sampling shows:
- Macro elevation slope is **unchanged** (retention-driven, not churn-driven).
- Micro elevation slope is **zero on both**; if anything the micro sawtooth
  *amplitude* is larger post-refactor (10.8 MB vs 2.2 MB), the opposite of the
  hypothesis phrasing — but this is noise-level and the reserved arena is flat.

The reason is the refc caveat: under `--mm:refc` the eliminated transient deep
copies (async-closure env captures, Result/Option bind-outs, redundant decode
buffers) are freed **deterministically** as each temporary leaves scope, and the
arena pages are reused in place. `getTotalMem` is *peak reserved*, not
*cumulative allocated*, so it plateaus once the arena is large enough; between
two 50-msg samples the transient churn has already been allocated **and** freed.
A coarse occupied/total sawtooth therefore **cannot** observe the transient-copy
reduction — and `gc_collections` is identical (10/10), reinforcing this.

**What the data *does* prove about memory:** the refactor lowers the **absolute
heap level** — peak heap −21 % (micro) / −20.7 % (macro), and a constant
~65–75 MB lower occupied baseline throughout the macro run. That is a real,
measurable memory win (fewer live temporaries at any instant, plus half the hash
buffers). It manifests as a **lower constant offset**, not a gentler slope or
smaller sawtooth.

**What *would* detect the transient-copy reduction directly:** a cumulative
bytes-allocated counter (instrumenting the Nim allocator or exposing
`GC_getStatistics` cumulative fields), or malloc-level profiling (macOS
Instruments Allocations, `heaptrack`, or valgrind `massif`), or a peak-RSS probe
under memory pressure. The current harness exposes none of these — a harness
gap, not a missing win.

## Bottom line

| Claim | Result |
|---|---|
| Throughput up | **micro +85.9 %, macro +56.6 %** |
| Redundant decode/hash removed | hashes/msg −50 % micro, decode+hash −40–50 % macro (byte-exact) |
| Peak heap down | **−21 % / −20.7 %** |
| Retained-memory slope changed by refactor | No (retention is workload-driven, identical) |
| Old code shows steeper allocation elevation | Not observable via occupied/total sampling under refc; win is a level shift, not a slope |
