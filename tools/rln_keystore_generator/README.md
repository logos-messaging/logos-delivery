# rln_keystore_generator

Generates an RLN keystore by registering a membership with the RLN smart contract.

It is exposed as the `generateRlnKeystore` subcommand of the node binary:

```bash
make logosdeliverynode
./build/logosdeliverynode generateRlnKeystore --help
```

Run it without `--execute` for a dry run: the credential is printed and no
transaction is sent.
