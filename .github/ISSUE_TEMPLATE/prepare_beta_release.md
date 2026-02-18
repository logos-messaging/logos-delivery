---
name: Prepare Beta Release
about: Execute tasks for the creation and publishing of a new beta release
title: 'Prepare beta release 0.0.0'
labels: beta-release
assignees: ''

---

<!--
Add appropriate release number to title!

For detailed info on the release process refer to https://github.com/logos-messaging/logos-delivery/blob/master/docs/contributors/release-process.md
 -->

### Items to complete

All items below are to be completed by the owner of the given release.

- [ ] Create release branch with major and minor only ( e.g. release/v0.X ) if it doesn't exist.
- [ ] Assign release candidate tag to the release branch HEAD (e.g. `v0.X.0-beta-rc.0`, `v0.X.0-beta-rc.1`, ... `v0.X.0-beta-rc.N`).
- [ ] Generate and edit release notes in CHANGELOG.md.

- [ ] **Validation of release candidate**
  - [ ] **Automated testing**
    - [ ] Ensure all the unit tests (specifically logos-messaging-js tests) are green against the release candidate.
  - [ ] **Waku fleet testing**
    - [ ] Deploy the release candidate to `waku.test` through [deploy-waku-test job](https://ci.infra.status.im/job/nim-waku/job/deploy-waku-test/) and wait for it to finish (Jenkins access required; ask the infra team if you don't have it).
      - After completion, disable fleet so that daily CI does not override your release candidate.
      - Verify at https://fleets.waku.org/ that the fleet is locked to the release candidate image.
      - Confirm the container image exists on [Harbor](https://harbor.status.im/harbor/projects/9/repositories/nwaku/artifacts-tab).
    - [ ] Search [Kibana logs](https://kibana.infra.status.im/app/discover) from the previous month (since the last release was deployed) for possible crashes or errors in `waku.test`.
      - Set time range to "Last 30 days" (or since last release).
      - Most relevant search query: `(fleet: "waku.test" AND message: "SIGSEGV")`, `(fleet: "waku.test" AND message: "exception")`, `(fleet: "waku.test" AND message: "error")`.
      - Document any crashes or errors found.
    - [ ] If `waku.test` validation is successful, deploy to `waku.sandbox` using the [deploy-waku-sandbox job](https://ci.infra.status.im/job/nim-waku/job/deploy-waku-sandbox/).
    - [ ] Search [Kibana logs](https://kibana.infra.status.im/app/discover) for `waku.sandbox`: `(fleet: "waku.sandbox" AND message: "SIGSEGV")`, `(fleet: "waku.sandbox" AND message: "exception")`, `(fleet: "waku.sandbox" AND message: "error")`. most probably if there are no crashes or errors in `waku.test`, there will be no crashes or errors in `waku.sandbox`.
    - [ ] Enable the `waku.test` fleet again to resume auto-deployment of the latest `master` commit.

- [ ] **Proceed with release**

  - [ ] Assign a final release tag (`v0.X.0-beta`) to the same commit that contains the validated release-candidate tag (e.g. `v0.X.0-beta-rc.N`) and submit a PR from the release branch to `master`.
  - [ ] Update [logos-delivery-compose](https://github.com/logos-messaging/logos-delivery-compose) and [logos-delivery-simulator](https://github.com/logos-messaging/waku-simulator) according to the new release.
  - [ ] Bump logos-delivery dependency in [logos-delivery-rust-bindings](https://github.com/logos-messaging/logos-delivery-rust-bindings) and make sure all examples and tests work.
  - [ ] Bump logos-delivery dependency in [logos-delivery-go-bindings](https://github.com/logos-messaging/logos-delivery-go-bindings) and make sure all tests work.
  - [ ] Create GitHub release (https://github.com/logos-messaging/logos-delivery/releases).
  - [ ] Submit a PR to merge the release branch back to `master`. Make sure you use the option "Merge pull request (Create a merge commit)" to perform the merge. Ping repo admin if this option is not available.

- [ ] **Promote release to fleets**
  - [ ] Ask the PM lead to announce the release.
  - [ ] Update infra config with any deprecated arguments or changed options.
  - [ ] Update waku.sandbox with [this deployment job](https://ci.infra.status.im/job/nim-waku/job/deploy-waku-sandbox/).

### Links

- [Release process](https://github.com/logos-messaging/logos-delivery/blob/master/docs/contributors/release-process.md)
- [Release notes](https://github.com/logos-messaging/logos-delivery/blob/master/CHANGELOG.md)
- [Fleet ownership](https://www.notion.so/Fleet-Ownership-7532aad8896d46599abac3c274189741?pvs=4#d2d2f0fe4b3c429fbd860a1d64f89a64)
- [Infra-nim-waku](https://github.com/status-im/infra-nim-waku)
- [Jenkins](https://ci.infra.status.im/job/nim-waku/)
- [Fleets](https://fleets.waku.org/)
- [Harbor](https://harbor.status.im/harbor/projects/9/repositories/nwaku/artifacts-tab)
- [Kibana](https://kibana.infra.status.im/app/)
