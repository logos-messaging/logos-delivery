---
name: Prepare Release
about: Execute tasks for the creation, validation, deployment and publishing of a new full release
title: 'Prepare release 0.0.0'
labels: full-release
assignees: ''

---

<!--
Add appropriate release number to title!

For detailed info on the release process refer to https://github.com/logos-messaging/logos-delivery/blob/master/docs/contributors/release-process.md
 -->

### Items to complete

All items below are to be completed by the owner of the given release.

- [ ] Create release branch with major and minor only ( e.g. release/v0.X ) if it doesn't exist.
- [ ] Update the `version` field in `logos_delivery.nimble` to match the release version (e.g. `version = "0.X.0"`) **and merge it before assigning any tag** - the `release-assets` workflow gates artifact build/upload.
- [ ] Assign release candidate tag to the release branch HEAD (e.g. `v0.X.0-rc.0`, `v0.X.0-rc.1`, ... `v0.X.0-rc.N`).
- [ ] Generate and edit release notes in CHANGELOG.md.

- [ ] **Validation of release candidate**

  - [ ] **Automated testing**
    - [ ] Ensure all the unit tests (specifically logos-messaging-js tests) are green against the release candidate.

  - [ ] **`waku.test` fleet validation** (primary validation environment for the release candidate)
    - [ ] Deploy the release candidate to the `waku.test` fleet.
      - Start the deployment job in [Jenkins](https://ci.infra.status.im/) and wait for it to finish (Jenkins access required; ask the infra team if you don't have it).
      - After completion, disable the fleet so that daily CI does not override your release candidate.
      - Verify at https://fleets.logos.co/ that the fleet is locked to the release candidate image.
      - Confirm the container image exists on [Harbor](https://harbor.status.im/harbor/projects/32/repositories/logos-node/artifacts-tab).
    - [ ] Search [Kibana logs](https://kibana.infra.status.im/app/discover) since the last release for crashes or errors in `waku.test`.
      - Most relevant search queries: `(fleet: "waku.test" AND message: "SIGSEGV")`, `(fleet: "waku.test" AND message: "exception")`, `(fleet: "waku.test" AND message: "error")`.
      - Document any crashes or errors found and fix them before proceeding.
    - [ ] Ensure QA tests run continuously against `waku.test` and are green.
    - [ ] Re-enable the `waku.test` fleet to resume auto-deployment of the latest `master` commit.
    <!-- In the future, automate `waku.test` crash detection so `master` stays continuously green and we can cut a release every week. -->

  - [ ] **Bindings testing**
    - [ ] Bump logos-delivery dependency in [logos-delivery-go-bindings](https://github.com/logos-messaging/logos-delivery-go-bindings) and make sure all tests work.

  - [ ] **DST sign-off** (done in advance, before deploying the release)
    - [ ] Inform the DST team about the expectations for this release. For example, if we expect higher, same or lower bandwidth consumption, or a new protocol appears, etc.
    - [ ] Ask DST to add a comment approving this release and add a link to the analysis report.

  - [ ] **Status testing**
    - [ ] Submit a PR on [status-go](https://github.com/status-im/status-go) bumping logos-delivery to this release.
    - [ ] Submit a PR on [status-app](https://github.com/status-im/status-mobile) bumping logos-delivery to this release.
    - [ ] Both PRs must be merged before the release is considered created.

- [ ] **Deployment and release** (merge of the former deployment process; involve Alberto)

  - [ ] Deploy to `status.prod`
    - [ ] Coordinate with the Infra Team about possible changes in CI behavior.
    - [ ] Ask the Status admin to add a comment approving that this deployment happen now.
    - [ ] Update `status.prod` with [this deployment job](https://ci.infra.status.im/job/nim-waku/job/deploy-status-prod/).
  - [ ] Update infra config
    - [ ] Submit PRs into infra repos to adjust deprecated or changed arguments (review CHANGELOG.md for that release). Confirm the fleet can run after that. This requires coordination with the infra team.

  - [ ] Assign a final release tag (`v0.X.0`) to the same commit that contains the validated release-candidate tag (e.g. `git tag -as v0.X.0 -m "final release."`).
  - [ ] Update [logos-delivery-compose](https://github.com/logos-messaging/logos-delivery-compose) and [logos-delivery-simulator](https://github.com/logos-messaging/logos-delivery-simulator) according to the new release.
  - [ ] Create GitHub release (https://github.com/logos-messaging/logos-delivery/releases).
  - [ ] Submit a PR to merge the release branch back to `master`. Make sure you use the option "Merge pull request (Create a merge commit)" to perform the merge. Ping repo admin if this option is not available.

### Links

- [Release process](https://github.com/logos-messaging/logos-delivery/blob/master/docs/contributors/release-process.md)
- [Release notes](https://github.com/logos-messaging/logos-delivery/blob/master/CHANGELOG.md)
- [Fleet ownership](https://www.notion.so/Fleet-Ownership-7532aad8896d46599abac3c274189741?pvs=4#d2d2f0fe4b3c429fbd860a1d64f89a64)
- [Infra-logos](https://github.com/status-im/infra-logos)
- [Infra-Status](https://github.com/status-im/infra-status)
- [Jenkins](https://ci.infra.status.im/)
- [Fleets](https://fleets.logos.co/)
- [Harbor](https://harbor.status.im/harbor/projects/32/repositories/logos-node/artifacts-tab)
- [Kibana](https://kibana.infra.status.im/app/)
