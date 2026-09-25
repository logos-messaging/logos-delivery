# Logos Delivery

[![ci](https://github.com/logos-messaging/logos-delivery/actions/workflows/ci.yml/badge.svg?branch=master&event=push)](https://github.com/logos-messaging/logos-delivery/actions/workflows/ci.yml?query=branch%3Amaster+event%3Apush)
[![Daily CI](https://github.com/logos-messaging/logos-delivery/actions/workflows/ci-daily.yml/badge.svg?event=schedule)](https://github.com/logos-messaging/logos-delivery/actions/workflows/ci-daily.yml?query=event%3Aschedule)
[![Nightly pre-release](https://github.com/logos-messaging/logos-delivery/actions/workflows/pre-release.yml/badge.svg?event=schedule)](https://github.com/logos-messaging/logos-delivery/actions/workflows/pre-release.yml?query=event%3Aschedule)
[![Nightly REST e2e](https://github.com/logos-messaging/logos-delivery/actions/workflows/e2e-rest-tests.yml/badge.svg?event=schedule)](https://github.com/logos-messaging/logos-delivery/actions/workflows/e2e-rest-tests.yml?query=event%3Aschedule)

## Introduction

This implements a set of libp2p protocols aimed at
private communication.

- Nim implementation of [these specs](https://github.com/logos-co/logos-lips/tree/master/docs/messaging).
- C library that exposes the implemented protocols.
- CLI application that allows you to run a logos-delivery node.
- Examples.
- Tests for all of the above.

For more details see the [source code](logos_delivery/waku/README.md)

## How to Build & Run ( Linux, MacOS & WSL )

These instructions are generic. For more detailed instructions, see the source code above.

Recommended and tested toolchain versions (these are installed when you follow the build instructions below):
- Nim 2.2.12
- Nimble: `make nimble` installs the pin from `logos_delivery.nimble`. Check it with the `git hash:` line of `nimble --version`.

`make` runs the pinned Nimble itself. To use it in a shell:

```bash
export PATH="$(make print-nimble-path):$PATH"
```

### Prerequisites

- The standard developer tools: a C/C++ compiler, GNU Make, Bash and Git.
- CMake.
- Rust (`rustc` and `cargo`).

> Some distributions (Fedora, for example) don't ship the `which` utility by default. The Makefile relies on it, so install it separately.

### Node

```bash
# The first `make` invocation will initialize the local dependency state.
make logosdeliverynode

# Build with custom compilation flags. Do not use NIM_PARAMS unless you know what you are doing.
# Replace with your own flags
make logosdeliverynode NIMFLAGS="-d:chronicles_colors:none -d:disableMarchNative"

# Run with DNS bootstrapping
./build/logosdeliverynode --dns-discovery-url=DNS_BOOTSTRAP_NODE_URL

# See available command line options
./build/logosdeliverynode --help
```
To join the network, you need to know the address of at least one bootstrap node.
Please refer to the [Waku README](https://github.com/logos-messaging/logos-delivery/blob/master/logos_delivery/waku/README.md) for more information.

For more on running a node, refer to the guides below. They were written for nwaku and still use the old `wakunode2` binary name:
- [Run using binaries](https://docs.waku.org/run-node/build-source)
- [Run using docker](https://docs.waku.org/run-node/run-docker)
- [Run using docker-compose](https://docs.waku.org/run-node/run-docker-compose)

#### Issues
##### WSL
If you encounter difficulties building the project on WSL, consider placing the project within WSL's filesystem, avoiding the `/mnt/` directory.

## How to Build & Run ( Windows )

#### 1. Install Required Tools
- **Git Bash Terminal**: Download and install from https://git-scm.com/download/win  
- **MSYS2**:  
  a. Download installer from https://www.msys2.org  
  b. Install at "C:\" (default location). Remove/rename the msys folder in case of previous installation.
  c. Use the mingw64 terminal from msys64 directory for package installation.

#### 2. Install Dependencies
Open MSYS2 mingw64 terminal and run the following one-by-one :
```bash
pacman -Syu --noconfirm  
pacman -S --noconfirm --needed mingw-w64-x86_64-toolchain  
pacman -S --noconfirm --needed base-devel make cmake upx  
pacman -S --noconfirm --needed mingw-w64-x86_64-rust  
pacman -S --noconfirm --needed mingw-w64-x86_64-postgresql  
pacman -S --noconfirm --needed mingw-w64-x86_64-gcc  
pacman -S --noconfirm --needed mingw-w64-x86_64-gcc-libs  
pacman -S --noconfirm --needed mingw-w64-x86_64-libwinpthread-git  
pacman -S --noconfirm --needed mingw-w64-x86_64-zlib  
pacman -S --noconfirm --needed mingw-w64-x86_64-openssl  
pacman -S --noconfirm --needed mingw-w64-x86_64-python
pacman -S --noconfirm --needed mingw-w64-x86_64-nasm
```

`make` does not install Nim on Windows: `install-nim` is skipped there, and dependency setup calls `nim`, so it must already be on PATH. Install the version `logos_delivery.nimble` declares in `RequiredNimVersion` yourself, with `choosenim` or the official Windows build. The `ci / build-windows` job installs the same version with `jiro4989/setup-nim-action`.

Verify before building:
```bash
which upx gcc g++ make cmake cargo rustc python nasm nim
nim --version
```

#### 3. Build logosdeliverynode
- Open Git Bash as administrator  
- clone the repository and cd into it
- Execute: `./scripts/build_windows.sh`

#### 4. Troubleshooting
If `logosdeliverynode.exe` or `liblogosdelivery` isn't generated:  
- **Missing Dependencies**: Verify with:  
  `which make cmake gcc g++ rustc cargo python upx nasm nim`  
  If missing, revisit Step 2 or ensure MSYS2 is at `C:\`  
- **Installation Conflicts**: Remove existing MinGW/MSYS2/Git Bash installations and perform fresh install

## Developing

### Nim and dependencies
The first `make` run installs Nim into `~/.nim/nim-<version>` (linked from `~/.nimble/bin`) unless the right version is already on PATH, and installs the project dependencies into `nimbledeps/pkgs2`.

### Test Suite

```bash
# Run all the tests
make test

# Run a specific test file
make test <test_file_path>
# e.g. : make test tests/app/test_all.nim

# Run a specific test name from a specific test file
make test <test_file_path> <test_name>
# e.g. : make test tests/app/test_all.nim "node setup is successful with default configuration"
```

### Building single test files

`make test <file>` builds the file to `build/<file>.bin` and runs it. To re-run it without rebuilding, run the binary directly:

```bash
make test tests/common/test_enr_builder.nim
./build/tests/common/test_enr_builder.nim.bin
```

### Testing against `js-waku`
Refer to [logos-delivery-js repo](https://github.com/logos-messaging/logos-delivery-js/tree/master/packages/tests) for instructions.

## Formatting

Nim files are expected to be formatted using [`nph`](https://github.com/arnetheduck/nph). `make build-nph` installs one if it is not already on your PATH.

To format a single file, run `make nph/<path to the .nim file>`.
For example:

```
make nph/logos_delivery/waku/waku_core.nim
```

A pre-commit hook is provided to format staged files at commit time.
Run the following command to install it:

```shell
make install-nph
```

## Examples

Examples can be found in the `examples` folder.
The chat apps (`chat2`, `chat2mix`, `chat2bridge`) live in `apps`.

## Tools

Tools such as `wakucanary`, `networkmonitor` and `liteprotocoltester` live in the `apps` folder, each with its own README. `tools/rln_keystore_generator` holds the RLN keystore generator.

## Bugs, Questions & Features

For an inquiry, or if you would like to propose new features, feel free to [open a general issue](https://github.com/logos-messaging/logos-delivery/issues/new).

For bug reports, please [tag your issue with the `bug` label](https://github.com/logos-messaging/logos-delivery/issues/new?labels=bug).

If you believe the reported issue requires critical attention, please [use the `critical` label](https://github.com/logos-messaging/logos-delivery/issues/new?labels=critical,bug) to assist with triaging.

To get help, or participate in the conversation, join the [Logos Discord](https://discord.gg/logosnetwork) server.

## Docs

* [REST API Documentation](https://logos-messaging.github.io/logos-delivery-rest-api/)
