---
name: Prepare Full Release
about: Execute tasks for the creation and publishing of a new full release
title: 'Prepare full release 0.0.0'
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
- [ ] Assign release candidate tag to the release branch HEAD (e.g. `v0.X.0-rc.0`, `v0.X.0-rc.1`, ... `v0.X.0-rc.N`).
- [ ] Generate and edit release notes in CHANGELOG.md.

- [ ] **Validation of release candidate**

  - [ ] **Automated testing**
    - [ ] Ensure all the unit tests (specifically logos-delivery-js tests) are green against the release candidate.
    - [ ] Ask Vac-QA and Vac-DST to perform the available tests against the release candidate.
    - [ ] Vac-DST (an additional report is needed; see [this](https://www.notion.so/DST-Reports-1228f96fb65c80729cd1d98a7496fe6f))

  - [ ] **Waku fleet testing**
    - [ ] Deploy the release candidate to `waku.test` and `waku.sandbox` fleets.
      - Start the [deployment job](https://ci.infra.status.im/job/nim-waku/) for both fleets and wait for it to finish (Jenkins access required; ask the infra team if you don't have it).
      - After completion, disable [deployment job](https://ci.infra.status.im/job/nim-waku/) so that its version is not updated on every merge to `master`.
      - Verify the deployed version at https://fleets.waku.org/.
      - Confirm the container image exists on [Harbor](https://harbor.status.im/harbor/projects/9/repositories/nwaku/artifacts-tab).
    - [ ] Search _Kibana_ logs from the previous month (since the last release was deployed) for possible crashes or errors in `waku.test` and `waku.sandbox`.
      - Most relevant logs are `(fleet: "waku.test" AND message: "SIGSEGV")` OR `(fleet: "waku.sandbox" AND message: "SIGSEGV")`.
    - [ ] Enable again the `waku.test` fleet to resume auto-deployment of the latest `master` commit.

- [ ] **Status fleet testing**
  - [ ] Deploy release candidate to `status.staging`
  - [ ] Perform [sanity check](https://www.notion.so/How-to-test-Nwaku-on-Status-12c6e4b9bf06420ca868bd199129b425) and log results as comments in this issue.
    - [ ] Connect 2 instances to `status.staging` fleet, one in relay mode, the other one in light client.
      - 1:1 Chats with each other
      - Send and receive messages in a community
      - Close one instance, send messages with second instance, reopen first instance and confirm messages sent while offline are retrieved from store
    - [ ] Perform checks based on _end user impact_
    - [ ] Inform other (Waku and Status) CCs to point their instances to `status.staging` for a few days. Ping Status colleagues on their Discord server or in the [Status community](https://status.app/c/G3kAAMSQtb05kog3aGbr3kiaxN4tF5xy4BAGEkkLwILk2z3GcoYlm5hSJXGn7J3laft-tnTwDWmYJ18dP_3bgX96dqr_8E3qKAvxDf3NrrCMUBp4R9EYkQez9XSM4486mXoC3mIln2zc-TNdvjdfL9eHVZ-mGgs=#zQ3shZeEJqTC1xhGUjxuS4rtHSrhJ8vUYp64v6qWkLpvdy9L9) (this is not a blocking point.)
    - [ ] Ask Status-QA to perform sanity checks (as described above) and checks based on _end user impact_; specify the version being tested
    - [ ] Ask Status-QA or infra to run the automated Status e2e tests against `status.staging`
    - [ ] Get other CCs' sign-off: they should comment on this PR, e.g., "Used the app for a week, no problem." If problems are reported, resolve them and create a new RC.
    - [ ] **Get Status-QA sign-off**, ensuring that the `status.test` update will not disturb ongoing activities.

- [ ] **Proceed with release**

  - [ ] Assign a final release tag (`v0.X.0`) to the same commit that contains the validated release-candidate tag (e.g. `v0.X.0`).
  - [ ] Update [logos-delivery-compose](https://github.com/logos-messaging/logos-delivery-compose) and [logos-delivery-simulator](https://github.com/logos-messaging/logos-delivery-simulator) according to the new release.
  - [ ] Bump logos-delivery dependency in [logos-delivery-rust-bindings](https://github.com/logos-messaging/logos-delivery-rust-bindings) and make sure all examples and tests work.
  - [ ] Bump logos-delivery dependency in [logos-delivery-go-bindings](https://github.com/logos-messaging/logos-delivery-go-bindings) and make sure all tests work.
  - [ ] Create GitHub release (https://github.com/logos-messaging/logos-delivery/releases).
  - [ ] Submit a PR to merge the release branch back to `master`. Make sure you use the option "Merge pull request (Create a merge commit)" to perform the merge. Ping repo admin if this option is not available.

- [ ] **Promote release to fleets**
  - [ ] Ask the PM lead to announce the release.
  - [ ] Update infra config with any deprecated arguments or changed options.

### Links

- [Release process](https://github.com/logos-messaging/logos-delivery/blob/master/docs/contributors/release-process.md)
- [Release notes](https://github.com/logos-messaging/logos-delivery/blob/master/CHANGELOG.md)
- [Fleet ownership](https://www.notion.so/Fleet-Ownership-7532aad8896d46599abac3c274189741?pvs=4#d2d2f0fe4b3c429fbd860a1d64f89a64)
- [Infra-nim-waku](https://github.com/status-im/infra-nim-waku)
- [Jenkins](https://ci.infra.status.im/job/nim-waku/)
- [Fleets](https://fleets.waku.org/)
- [Harbor](https://harbor.status.im/harbor/projects/9/repositories/nwaku/artifacts-tab)
