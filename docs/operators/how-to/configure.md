# Configure a nwaku node

Nwaku can be configured to serve the adaptive needs of different operators.

> :bulb: **Tip:** The recommended configuration method is through environment variables.

## Node configuration methods

One node can be configured using a combination of the following methods:

1. Command line options and flags
2. Environment variables
3. Configuration file (currently, only TOML format is supported)
4. Default value

Note the precedence order, each configuration mechanism overrides the configuration set by one below (e.g., _command line options_ override the configuration set by the _environment variables_ and by the _configuration file_).

### Command line options/flags

The main mechanism to configure the node is via command line options. Any configuration option provided via the command line will override any other configuration mechanism.

> :warning: nwaku is under heavy development. It is likely that configuration will change from one version to another.
>
> If after an upgrade, the node refuses to start, check if any of the command line configuration options provided to the node have been changed or removed.
> 
> To overcome this issue, we recommend to configure the node via environment variables.

The configuration options should be provided after the binary name as follows:

```shell
wakunode2 --tcp-port=65000
```

In the case of using docker to run you node you should provide the commandline options after the image name as follows:

```shell
docker run wakuorg/nwaku --tcp-port=65000
```

Run `wakunode2 --help` to get a comprehensive list of configuration options (and its default values):

```shell
$ wakunode2 --help
Usage: 

wakunode2 [OPTIONS]...

The following options are available:

 --config-file             Loads configuration from a TOML file (cmd-line parameters take precedence).
 --log-level               Sets the log level. [=LogLevel.INFO].
 --version                 prints the version [=false].

<...>
```

Check the configuration tutorials for specific configuration use cases.

### Environment variables

The node can also be configured via environment variables. 

> :information_source: Support for configuring the node via environment variables was added in v0.13.0

The environment variable name should be prefixed by the app's name, in this case `WAKUNODE2_` followed by the commandline option in [screaming snake case](https://en.wiktionary.org/wiki/screaming_snake_case). 

For example, to set the `--tcp-port` configuration we should call `wakunode2` binary as follows:

```shell
WAKUNODE2_TCP_PORT=65000 wakunode2
```

In the case of using docker to run you node you should start the node using the `-e` command options:

```shell
docker run -e "WAKUNODE2_TCP_PORT=65000" wakuorg/nwaku
```

This is the second configuration method in order of precedence. Any command line configuration option will override the configuration
provided via environment variables.

### Configuration file

The third configuration mechanism in order of precedence is the configuration via a TOML file. The previous mechanisms take precedence over this mechanism as explained above.

The configuration file follows the [TOML](https://toml.io/en/) format:

```toml
log-level = "DEBUG"
tcp-port = 65000
```

The path to the TOML file can be specified using one of the previous configuration mechanisms:

* By passing the `--config-file` command line option:
  ```shell
  wakunode2 --config-file=<path-to-toml-config-file>
  ```
* By passing the path via environment variables:
  ```shell
  WAKUNODE2_CONFIG_FILE=<path-to-toml-config-file> wakunode2
  ```

### Configuration default values

As usual, if no configuration option is specified by any of the previous mechanisms, the default configuration will be used.

The default configuration value is listed in the `wakunode2 --help` output:

```shell
$ wakunode2 --help
Usage: 

wakunode2 [OPTIONS]...

The following options are available:

 --config-file             Loads configuration from a TOML file (cmd-line parameters take precedence).
 --log-level               Sets the log level. [=LogLevel.INFO].
 --version                 prints the version [=false].--tcp-port                TCP listening port. [=60000].
 --websocket-port          WebSocket listening port. [=8000].
<...>
```

## Configuration use cases

This is an index of tutorials explaining how to configure your nwaku node for different use cases.

1. [Connect to other peers](./connect.md)
2. [Configure a domain name](./configure-domain.md)
3. [Use DNS discovery to connect to existing nodes](./configure-dns-disc.md)
4. [Configure store protocol and message store](./configure-store.md)
5. [Generate and configure a node key](./configure-key.md)
6. [Configure websocket transport](./configure-websocket.md)
7. [Configure QUIC transport](./configure-quic.md)
8. [Run nwaku with rate limiting enabled](./run-with-rln.md)
9. [Configure a REST API node](./configure-rest-api.md)
