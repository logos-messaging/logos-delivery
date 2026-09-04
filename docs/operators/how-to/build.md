# Build nwaku

Nwaku can be built on Linux and macOS.
Windows support is experimental.

## Installing dependencies

Cloning and building nwaku requires the usual developer tools,
such as a C compiler, Make, Bash and Git.

### Linux

On common Linux distributions the dependencies can be installed with

```sh
# Debian and Ubuntu
sudo apt-get install build-essential git

# Fedora
dnf install @development-tools

# Archlinux, using an AUR manager
yourAURmanager -S base-devel
```

### macOS

Assuming you use [Homebrew](https://brew.sh/) to manage packages

```sh
brew install cmake
```

## Building nwaku

### 1. Clone the nwaku repository

```sh
git clone https://github.com/status-im/nwaku
cd nwaku
```

### 2. Make the `wakunode2` target

```sh
# The first `make` invocation will update all Git submodules.
make wakunode2
```

This will create a `wakunode2` binary in the `./build/` directory.

> **Note:** Building `wakunode2` requires 2GB of RAM.
The build will fail on systems not fulfilling this requirement. 

> Setting up a `wakunode2` on the smallest [digital ocean](https://docs.digitalocean.com/products/droplets/how-to/) droplet, you can either
> * compile on a stronger droplet featuring the same CPU architecture and downgrade after compiling, or
> * activate swap on the smallest droplet, or
> * use Docker.
