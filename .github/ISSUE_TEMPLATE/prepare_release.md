---
name: Prepare Release
about: Execute tasks for the creation, validation, deployment and publishing of a new full release
title: 'Prepare release 0.0.0'
labels: full-release
assignees: ''

---

<!--
Add appropriate release number to title
 -->

### Items to complete, in order

#### Initial validation
  - [ ] Confirm waku.test has been running with new commits on each merge into master (see Grafana boards.)
  - [ ] Search [Kibana logs](https://kibana.infra.status.im/app/discover) since the last release for crashes or errors in waku.test that we didn't detect in CI.
    - Most relevant search queries: `(fleet: "waku.test" AND message: "SIGSEGV")`, `(fleet: "waku.test" AND message: "exception")`, `(fleet: "waku.test" AND message: "error")`.
    - Detect unexpected reboots.
    - Document any crashes or errors found and fix them before proceeding.

- [ ] Create release branch with major and minor only ( e.g. release/v0.X ).
- [ ] In release branch, update the `version` field in `logos_delivery.nimble` to match the release version (e.g. `version = "0.X.0"`).
- [ ] Assign release candidate tag to the release branch HEAD (e.g. `v0.X.0-rc.0`, `v0.X.0-rc.1`, ... `v0.X.0-rc.N`).

- [ ] Validate the release candidate

  - [ ] 1. Essential test
    - [ ] Ensure all unit tests are green
    - [ ] Get interop tests results from QA

  - [ ] 2. Fleet validation (pre-requisite: 1. Can be done in parallel with 3.)
    - [ ] Deploy the release candidate to the waku.test fleet.
      - Start the deployment job in [Jenkins](https://ci.infra.status.im/) and wait for it to finish (Jenkins access required; ask the infra team if you don't have it).
      - Confirm the container image exists on [Harbor](https://harbor.status.im/harbor/projects/32/repositories/logos-node/artifacts-tab).
      - After completion, disable the fleet so that daily CI does not override your release candidate.
      - Verify at https://fleets.logos.co/ that the fleet is locked to the release candidate image.
    
    - [ ] Ask QA to run tests against waku.test and attach a screenshot as evidence.
    - [ ] Re-enable the waku.test fleet to resume auto-deployment of the latest master commit.
    <!-- In the future, automate `waku.test` crash detection so `master` stays continuously green and we can cut a release easier. -->

  - [ ] 3. DST sign-off (pre-requisite: 1)
    - [ ] Inform the DST team about the expectations for this release. For example, if we expect higher, same or lower bandwidth consumption, or a new protocol appears, etc.
    - [ ] Ask DST to add a comment approving this release and add a summary analysis report.

  - [ ] 4. Status testing (pre-requisite: 1, 2, 3)
    - [ ] Bump logos-delivery dependency in [logos-delivery-go-bindings](https://github.com/logos-messaging/logos-delivery-go-bindings) and make sure all tests work.
    - [ ] Submit a PR on [status-go](https://github.com/status-im/status-go/blob/1f9061064587e1167e32d965d5a6f2b745324d5e/tests-functional/docker-compose.waku.yml#L3) bumping logos-delivery to this release candidate.
    - [ ] Submit a PR on [status-app](https://github.com/status-im/status-app/blob/3639e28374ca3c2158ac2dac6af35dbce439b10a/docker-compose.waku.yml#L3) bumping logos-delivery to this release candidate.
    - [ ] Both PRs must be merged before the release is considered created.
    - [ ] Deploy the release candidate in status.staging. That may alert about needed infra changes.

  - [ ] 5. Submit a PR against release/v0.X with CHANGELOG.md updates (pre-requisite: all previous.)

- [ ] Deployment and release

  - [ ] Deploy to waku.sandbox
    - [ ] Confirm the release candidate ran properly in waku.test with the current infra config.
      - [ ] If it did NOT (e.g. CLI params changed): submit PRs to the infra repos adjusting the deprecated or changed arguments (review CHANGELOG.md for that release), add links to them, and wait until they are merged. Infra changes are deployed by the infra team, so this requires coordination with them.
      - [ ] If it ran fine with the current config, no infra PR is needed.
    - [ ] Deploy:
      - [ ] Coordinate with the Infra Team about the deployment timing.
      - [ ] Update waku.sandbox with [this deployment job](https://ci.infra.status.im/job/nim-waku/job/deploy-waku-sandbox/).
      - [ ] Confirm the fleet runs properly after the deployment.
  - [ ] Deploy to status.prod
    - [ ] Confirm the release candidate ran properly in status.staging with the current infra config.
      - [ ] If it did NOT (e.g. CLI params changed): submit PRs to the infra repos adjusting the deprecated or changed arguments (review CHANGELOG.md for that release), add links to them, and wait until they are merged. Infra changes are deployed by the infra team, so this requires coordination with them.
      - [ ] If it ran fine with the current config, no infra PR is needed.
    - [ ] Deploy:
      - [ ] Ask the Status admin to add a comment approving that this deployment happen now.
      - [ ] Update status.prod with [this deployment job](https://ci.infra.status.im/job/nim-waku/job/deploy-status-prod/).
      - [ ] Confirm the fleet runs properly after the deployment.

  - [ ] Assign a final release tag (`v0.X.0`) to the same commit that contains the latest release-candidate tag (e.g. `git tag -as v0.X.0 -m "final release."`).
  - [ ] Update [logos-delivery-compose](https://github.com/logos-messaging/logos-delivery-compose) and [logos-delivery-simulator](https://github.com/logos-messaging/logos-delivery-simulator) according to the new release.
  - [ ] Create GitHub release (https://github.com/logos-messaging/logos-delivery/releases).
  - [ ] Merge release branch into master
    - [ ] Create a temporary branch from the release branch. This is needed in case we need to rebase that branch without impacting the release branch. Notice that the release branch should live forever.
    - [ ] Submit a PR from temporary branch to master. Make sure you use the option "Merge pull request (Create a merge commit)" to perform the merge. Ping repo admin if this option is not available.
  - [ ] Adjust status-go, status-app Makefiles to make sure they use the final tag instead of release candidate one.

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
