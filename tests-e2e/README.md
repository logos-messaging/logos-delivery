# tests-e2e — logos-delivery API/e2e tests (Python)

End-to-end tests for `liblogosdelivery`, driven through the Python bindings (C-FFI).
Migrated from [`logos-delivery-interop-tests`](https://github.com/logos-messaging/logos-delivery-interop-tests) (the wrapper / send-API suite).

## Layout

- `src/` — test framework (node wrappers, steps, helpers)
- `tests/wrappers_tests/` — the API/e2e scenario tests (`test_s02…s31`)
- `vendor/logos-delivery-python-bindings/waku/wrapper.py` — CFFI binding (`NodeWrapper`); it `dlopen`s `../lib/liblogosdelivery.so`

## Run locally

```bash
# 1. Build the shared library and place it where the binding looks for it
./tests-e2e/scripts/prepare_lib.sh

# 2. Python env + deps
python -m venv .venv && source .venv/bin/activate
pip install -r tests-e2e/requirements.txt

# 3. Run (from tests-e2e/)
cd tests-e2e
pytest tests/wrappers_tests -m "not docker_required"   # 51 pure-binding tests
pytest tests/wrappers_tests -m docker_required          # 5 tests that also need a Docker nwaku peer (S11/S19/S20/S25/S31)
```

## CI

`.github/workflows/e2e-api-tests.yml` (called from `ci.yml`, `needs: build`) downloads the
`liblogosdelivery` artifact produced by the `build` job and runs the non-docker subset on every PR —
so a protocol change and its e2e test land in the same PR.
