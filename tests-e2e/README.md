# tests-e2e — logos-delivery API/e2e tests (Python)

End-to-end tests for `liblogosdelivery`, driven through the Python bindings (C-FFI).
Migrated from [`logos-delivery-interop-tests`](https://github.com/logos-messaging/logos-delivery-interop-tests) (the wrapper / send-API suite).

## Layout

- `src/` — test framework (node wrappers, steps, helpers)
- `tests/c_abi/` — scenario tests that drive `liblogosdelivery` through its C ABI (`test_s02…s31`)
- `tests/rest/` — REST tests against docker nodes (`DEFAULT_NWAKU` image); `tests/rest/messaging/` covers the `/messaging/v1` endpoints
- `vendor/logos-delivery-python-bindings/` — git submodule of [`logos-delivery-python-bindings`](https://github.com/logos-messaging/logos-delivery-python-bindings), pinned to a commit. Its `logosdelivery/wrapper.py` is the CFFI binding (`NodeWrapper`); it `dlopen`s `../lib/liblogosdelivery.so`. `.gitmodules` sets `update = none` for it, so a plain `git submodule update` skips it and `prepare_lib.sh` checks it out.

## Run locally

```bash
# 1. Check out the binding, build the shared library and place it where the binding looks for it
./tests-e2e/scripts/prepare_lib.sh

# 2. Python env + deps
python -m venv .venv && source .venv/bin/activate
pip install -r tests-e2e/requirements.txt

# 3. Run (from tests-e2e/)
cd tests-e2e
pytest tests/c_abi -m "not docker_required and not slow"   # 60 pure-binding tests, the CI selection
pytest tests/c_abi -m docker_required                      # 5 tests that also need a Docker nwaku peer (S11/S19/S20/S25/S31)
pytest tests/c_abi -m slow                                 # 1 SDS-R repair test, minutes long
# REST suites run docker nodes from DEFAULT_NWAKU (default: the nightly image, built from master).
# To test local changes, build an image and set DEFAULT_NWAKU to it; the name must contain "nwaku".
DEFAULT_NWAKU=<image> pytest tests/rest/messaging
```

## Updating the binding

Move the submodule to the new commit and stage the pointer:

```bash
git -C tests-e2e/vendor/logos-delivery-python-bindings fetch origin
git -C tests-e2e/vendor/logos-delivery-python-bindings checkout <commit>
git add tests-e2e/vendor/logos-delivery-python-bindings
```

## CI

`.github/workflows/tests-e2e-c-abi.yml` (called from `ci.yml`, `needs: [build, build-docker-image]`) downloads the
`liblogosdelivery` artifact produced by the `build` job and runs the non-docker and docker subsets as a matrix
(`c-abi`, `c-abi-docker`) on every PR — so a protocol change and its e2e test land in the same PR.

The `slow` test is deselected there. `.github/workflows/tests-e2e-c-abi-nightly.yml` (nightly, also on manual dispatch)
builds the library from the checkout and runs the whole non-docker subset, `slow` included.
Run it by hand when touching SDS-R.
