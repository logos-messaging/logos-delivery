# Logos Messaging Nim

## Introduction

This repository implements a set of libp2p protocols aimed to bring
private communications.

- Nim implementation of [these specs](https://github.com/logos-co/logos-lips/tree/master/docs/messaging).
- C library that exposes the implemented protocols.
- CLI application that allows you to run a logos-delivery node.
- Examples.
- Various tests of above.

For more details see the [source code](waku/README.md)

## How to Build & Run ( Linux, MacOS & WSL )

These instructions are generic. For more detailed instructions, see the source code above.

Recommended and tested toolchain versions (these are installed when you follow the build instructions below):
- Nim 2.2.4
- Nimble 0.22.3

### Prerequisites

The standard developer tools, including a C compiler, GNU Make, Bash, and Git.

> In some distributions (Fedora linux for example), you may need to install `which` utility separately. Nimbus build system is relying on it.

You'll also need an installation of Rust and its toolchain (specifically `rustc` and `cargo`).
The easiest way to install these, is using `rustup`:

Rust:
```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
```

### Wakunode

```bash
# The first `make` invocation will initialize the local dependency state.
make wakunode2

# Build with custom compilation flags. Do not use NIM_PARAMS unless you know what you are doing.
# Replace with your own flags
make wakunode2 NIMFLAGS="-d:chronicles_colors:none -d:disableMarchNative"

# Run with DNS bootstrapping
./build/wakunode2 --dns-discovery --dns-discovery-url=DNS_BOOTSTRAP_NODE_URL

# See available command line options
./build/wakunode2 --help
```
To join the network, you need to know the address of at least one bootstrap node.
Please refer to the [Waku README](https://github.com/logos-messaging/logos-delivery/blob/master/waku/README.md) for more information.

For more on how to run `wakunode2`, refer to:
- [Run using binaries](https://docs.waku.org/run-node/build-source)
- [Run using docker](https://docs.waku.org/run-node/run-docker)
- [Run using docker-compose](https://docs.waku.org/run-node/run-docker-compose)

#### Issues
##### WSL
If you encounter difficulties building the project on WSL, consider placing the project within WSL's filesystem, avoiding the `/mnt/` directory.

### How to Build & Run ( Windows )

### Windows Build Instructions

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
```

#### 3. Build Wakunode
- Open Git Bash as administrator  
- clone nwaku and cd nwaku
- Execute: `./scripts/build_windows.sh`

#### 4. Troubleshooting
If `wakunode2.exe` isn't generated:  
- **Missing Dependencies**: Verify with:  
  `which make cmake gcc g++ rustc cargo python3 upx`  
  If missing, revisit Step 2 or ensure MSYS2 is at `C:\`  
- **Installation Conflicts**: Remove existing MinGW/MSYS2/Git Bash installations and perform fresh install

### Developing

#### Nim Runtime
This repository is bundled with a Nim runtime that includes the necessary dependencies for the project.

Before you can utilize the runtime you'll need to build the project, as detailed in a previous section.
This will generate a `nimbledeps/pkgs2` directory containing various dependencies.

If everything went well, you should see your prompt suffixed with `[SuccessX]`. Now you can run `nim` commands as usual.

### Test Suite

```bash
# Run all the Waku tests
make test

# Run a specific test file
make test <test_file_path>
# e.g. : make test tests/wakunode2/test_all.nim

# Run a specific test name from a specific test file
make test <test_file_path> <test_name>
# e.g. : make test tests/wakunode2/test_all.nim "node setup is successful with default configuration"
```

### Building single test files

During development it is helpful to build and run a single test file.
To support this make has a specific target:

targets:
- `build/<relative path to your test file.nim>`
- `test/<relative path to your test file.nim>`

Binary will be created as `<path to your test file.nim>.bin` under the `build` directory .

```bash
# Build and run your test file separately
make test/tests/common/test_enr_builder.nim
```

### Testing against `js-waku`
Refer to [logos-delivery-js repo](https://github.com/logos-messaging/logos-delivery-js/tree/master/packages/tests) for instructions.

## Formatting

Nim files are expected to be formatted using the [`nph`](https://github.com/arnetheduck/nph) version present in `vendor/nph`.

You can easily format file with the `make nph/<relative path to nim> file` command.
For example:

```
make nph/waku/waku_core.nim
```

A convenient git hook is provided to automatically format file at commit time.
Run the following command to install it:

```shell
make install-nph
```

### Examples

Examples can be found in the examples folder.
This includes a fully featured chat example.

### Tools

Different tools and their corresponding how-to guides can be found in the `tools` folder.

### Bugs, Questions & Features

For an inquiry, or if you would like to propose new features, feel free to [open a general issue](https://github.com/logos-messaging/logos-delivery/issues/new).

For bug reports, please [tag your issue with the `bug` label](https://github.com/logos-messaging/logos-delivery/issues/new).

If you believe the reported issue requires critical attention, please [use the `critical` label](https://github.com/logos-messaging/logos-delivery/issues/new?labels=critical,bug) to assist with triaging.

To get help, or participate in the conversation, join the [Logos Discord](https://discord.gg/logosnetwork) server.

### Docs

* [REST API Documentation](https://logos-messaging.github.io/logos-delivery-rest-api/)