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
- [ ] Make sure master has `version = "0.X.0"` in `logos_delivery.nimble` (bump via PR if needed).
- [ ] Tag a green master commit as `v0.X.0-rc.0`.
- [ ] Create `release/v0.X` from the RC tag.

### 2. DST validation
- [ ] Share the RC with DST, stating what to expect (bandwidth, new protocols, etc.).
- [ ] DST comments here approving the RC, with a short report.
- [ ] If DST finds issues, merge the fixes into `release/v0.X` via PRs, tag `v0.X.0-rc.N+1` and repeat DST validation.

### 3. Release
- [ ] Tag the validated RC commit as `v0.X.0` (`git tag -as v0.X.0 -m "final release."`).
- [ ] Update CHANGELOG.md and create the [GitHub release](https://github.com/logos-messaging/logos-delivery/releases).
- [ ] Merge `release/v0.X` back into master (merge commit).

### 4. Status
- [ ] PR to [status-go](https://github.com/status-im/status-go) bumping logos-delivery to `v0.X.0`.
- [ ] PR to [status-app](https://github.com/status-im/status-app) bumping logos-delivery to `v0.X.0`.

### Links
- [CHANGELOG](https://github.com/logos-messaging/logos-delivery/blob/master/CHANGELOG.md)
