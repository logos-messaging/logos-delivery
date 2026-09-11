# rln_keystore_generator

Generates an RLN keystore by registering a membership with the RLN smart contract.

It is built as the `rlnkeystore` tool:

```bash
make rlnkeystore
./build/rlnkeystore --help
```

Node images ship it too:

```bash
docker run --entrypoint rlnkeystore <node-image> --help
```

Run it without `--execute` for a dry run: the credential is printed and no
transaction is sent.
