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
  1. Edit manually waku.nimble. For some dependencies, we want to bump versions manually and use a pinned version, f.e., nim-libp2p and all its dependencies.
  2. Run `nimble lock` (make sure `nimble --version` shows the Nimble version pinned in waku.nimble)
  3. Run `./tools/gen-nix-deps.sh nimble.lock nix/deps.nix` to update nix deps

- [ ] Update vendor/zerokit dependency.
