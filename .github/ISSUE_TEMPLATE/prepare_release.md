---
name: Prepare Release
about: Create a release candidate, get DST sign-off, publish the release and bump Status
title: 'Prepare release 0.0.0'
labels: full-release
assignees: ''

---

<!--
Add appropriate release number to title
 -->

### 1. Release candidate
- [ ] Create `release/v0.X` from a green master commit and set `version = "0.X.0"` in `logos_delivery.nimble`.
- [ ] Tag the branch HEAD as `v0.X.0-rc.N`.

### 2. DST validation
- [ ] Share the RC with DST, stating what to expect (bandwidth, new protocols, etc.).
- [ ] DST comments here approving the RC, with a short report. If not, fix and go back to 1 with `rc.N+1`.

### 3. Release
- [ ] Tag the validated RC commit as `v0.X.0` (`git tag -as v0.X.0 -m "final release."`).
- [ ] Update CHANGELOG.md and create the [GitHub release](https://github.com/logos-messaging/logos-delivery/releases).
- [ ] Merge `release/v0.X` into master (merge commit).

### 4. Status
- [ ] PR to [status-go](https://github.com/status-im/status-go) bumping logos-delivery to `v0.X.0`.
- [ ] PR to [status-app](https://github.com/status-im/status-app) bumping logos-delivery to `v0.X.0`.

### Links
- [CHANGELOG](https://github.com/logos-messaging/logos-delivery/blob/master/CHANGELOG.md)
