# ADR-0001: Let callers build liblogosdelivery with plain `nim c`

## Context and Problem Statement

liblogosdelivery is a C library that embedders build from source: status-go for the Status App, the Go bindings (`logos-delivery-go-bindings`), and the Logos Core delivery module through Nix. Since #3798, logos-delivery is a Nimble package: `logos_delivery.nimble` declares its requirements, `nimble.lock` pins them, and nimbus-build-system and the vendored package submodules are gone.

Embedders first built the library through Nimble tasks that the package shipped (`nimble liblogosdelivery` and per-platform tasks, #4137 and #4504). That moved the embedders' concerns into the library:
- Android NDK discovery and iOS SDK flags.
- Rebuilding `nat_traversal`'s archives, and writing stub tests into nim-leopard, inside the installed packages.
- A fixed memory manager and log level.
- The repository's root `config.nims`, installed with the package so that it reached the caller's build.

nim-sds and nim-token-lists had their own tasks, each with different knobs. status-go had to learn every one of them. The libraries were also built with different compilers and flags (refc in one, ORC in another), even though they end up in one process. The Status App's move from nimbus-build-system to Nimble (status-im/status-app#19907) was the point at which one approach for all of them was settled.

## Decision

liblogosdelivery is built like any other Nim library. The caller compiles its entry module with plain `nim c`, against the caller's own Nimble resolution. The package ships no build tasks for it.

The library's build contract has three parts:
- **Entry module:** `library/liblogosdelivery.nim`.
- **Public headers:** `library/*.h`. They include `generated/logosdelivery.h`, which nim-ffi writes.
- **C API prefix:** `logosdelivery_`. Every exported function carries it, and nothing else is meant to be exported.

`library/config.nims`, next to the entry, is the library's default configuration. It holds what the library is and what its code needs: threads, `--deepcopy:on`, no main, the generated header and `nimMainPrefix`, the nim-ffi C bindings, the feature defines and warning switches, the chronicles sinks per OS, and the Android C++ runtime. Nim reads this file even under `--skipParentCfg`, and the caller's flags come later, so they win. Unless the caller passes `-d:ffiOutputDir`, the generated header goes to `<nimcache>/generated`, so nothing is written into a read-only installed package. The root `config.nims` is not part of the contract and is not installed.

A caller builds the library like this, with the `--path` entries taken from its own `nimble.paths`:

```sh
nim c --skipParentCfg --noNimblePath <target> <policy> --path:<deps> \
  --nimcache:<out>/nimcache -o:<out>/<lib> <pkg>/library/liblogosdelivery.nim
```

The caller owns:
- **The target and toolchain:** OS and CPU, the NDK or SDK compiler, and `-fPIC`. For cross builds this includes `LeopardCmakeFlags`; without them, Leopard-RS adds `-march=native`.
- **The policy:** `--mm`, `--opt`, `-d:release` and the log level.
- **RLN:** either `-d:disable_rln` or a link against librln.
- **The link:** a `--app:staticlib` archive holds only the Nim objects, so a static consumer links libleopard and the C++ runtime itself. When several Nim runtimes share one image, the caller seals the archive: it keeps `logosdelivery_*` global and hides everything else. Only the caller knows what shares its link. status-go does this for the Status App.

`nimble.lock` pins only this repository's own builds: Make, CI and `nix/deps.nix`. A dependent resolves `logos_delivery.nimble` from its own root, and the dependent's lock decides what ships. When two packages pin different commits of a dependency, Nimble keeps the root's pin. PR CI installs from our lock, so it does not prove that a dependent can still resolve the manifest. For PRs that change the manifest, `consumer-break-check` (#4461) and `lock-break-check` (#4462) cover that.

This repository's Makefile, CI and Nix package are callers like any other. They run the same `nim c` with the flags they used before, and they also load the root `config.nims` as a parent configuration. A CI step builds the library the embedder's way, with no parent config and no `-d:ffiOutputDir`, and checks that the headers land under its `--nimcache`.

We accept these costs:
- Every caller repeats the target recipe: Android NDK, iOS SDK, Leopard-RS flags and the librln link.
- The library does not reject a policy it was not tested under. The policy is the caller's choice.
- A static consumer must link libleopard and the C++ runtime, and seal the archive when it shares an image.

Out of scope:
- Compiling all of an application's Nim code into one Nim runtime.
- The prebuilt artifacts that `release-assets.yml` publishes. They remain a convenience, not the integration path.

## Alternatives Considered

- **Nimble build tasks in the package** (#4137, #4504). Dependents get one command, but the tasks carry each target's toolchain knowledge, write into installed packages and fix the policy, and every library's tasks differ. #4744 replaced them.
- **Build from a clone with this repository's Makefile**, as status-go used to build nim-sds. This uses our lock and flags instead of the embedder's resolution and policy, so the embedder cannot build all of its Nim libraries with one compiler and one policy. It also needs a second checkout outside the package manager.
- **Ship prebuilt binaries as the integration path.** Embedders would need no Nim toolchain, but the target set, policy and Nim version would be fixed. Sealing also needs the objects, not a finished binary.
- **The library seals its own archive**, as nim-sds did on Mach-O. This assumes the archive will share a link with another Nim runtime, and it duplicates one recipe in every library. Rejected: only the linker of the final image knows what shares it.
- **Toolchain defaults in `library/config.nims`**, for example the NDK compiler taken from `ANDROID_NDK_ROOT`. A hand-typed `nim c --os:android` would work, but target knowledge would then live in every library as well as in every caller.
- **One Nim runtime per process**, with the embedder compiling all of its Nim code in one compile. This gives a smaller binary and one memory manager. It is not pursued for now, because Logos Core modules ship as separately built images.

## More Information

- Nimble migration of this repository: #3798. Build tasks for dependents: #4137, #4504. Plain `nim c`: #4744. Resolution checks: #4461, #4462. Leopard-RS without test executables: logos-storage/nim-leopard#34.
- The same contract is used by nim-sds (logos-messaging/nim-sds#115, which still keeps a convenience `libsds` task) and by nim-token-lists (status-im/nim-token-lists#26).
- Callers:
  - status-go builds and seals the library (status-im/status-go#8045), but does not link it into libstatus yet.
  - sds-go-bindings builds nim-sds this way (logos-messaging/sds-go-bindings#37). The same change for logos-delivery-go-bindings is in logos-messaging/logos-delivery-go-bindings#156.
- How the Status App resolves, builds and links its Nim libraries is recorded in [status-app ADR-0009](https://github.com/status-im/status-app/blob/master/docs/adr/0009-nim-libraries-resolved-by-nimble-built-by-status-go.md).
- Revisit if Logos Core offers a way to compile Nim modules into one host runtime, or if the target recipe duplicated across callers starts to drift.
