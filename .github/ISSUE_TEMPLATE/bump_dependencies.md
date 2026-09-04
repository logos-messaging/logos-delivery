---
name: Bump dependencies
about: Bump dependencies for release
title: 'Bump dependencies for release 0.X.0'
labels: dependencies
assignees: ''

---

<!-- Add appropriate release number to title! -->

### Bumped items
- [ ] Update nimble dependencies
  1. Edit manually logos_delivery.nimble. For some dependencies, we want to bump versions manually and use a pinned version, f.e., nim-libp2p and all its dependencies.
  2. Run `nimble lock` (make sure `nimble --version` shows the Nimble version pinned in logos_delivery.nimble). `nimble lock` is the canonical lock writer; `tools/sync-nimble-lock.sh` predates Nimble 0.24 and is legacy
  3. Run `./tools/gen-nix-deps.sh nimble.lock nix/deps.nix` to update nix deps
  4. Build: the audit (scripts/audit_deps.nims) must report that every installed package matches nimble.lock

- [ ] Update vendor/zerokit dependency.
