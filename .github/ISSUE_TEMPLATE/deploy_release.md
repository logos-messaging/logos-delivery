---
name: Deploy Release
about: Execute tasks for deploying a new version in a fleet
title: 'Deploy release vX.X.X in waku.sandbox and/or status.prod fleet'
labels: deploy-release
assignees: ''

---

<!--
Add appropriate release number and adjust the target fleet in the title!
 -->

### Link to the Release PR

<!--
Kindly add a link to the release PR where we have a sign-off from QA. At this time, that release PR should be already merged.
 -->

### Items to complete, in order

<!--
You can release into either waku.sanbox, status.prod, or both. Both cases require coordination with Infra Team.
waku.sandbox must be considered a prod fleet as it is used by external parties.
For both status.prod it is crucial to coordinate such deployment with Status Team.
The following points should be followed in order.
 -->

- [ ] Receive sign-off from DST.
  - [ ] Inform DST team about what are the expectations for this release. For example, if we expect higher, same or lower bandwidth consumption. Or a new protocol appears, etc.
  - [ ] Ask DST to add a comment approving this deployment and add a link to the analysis report.

- [ ] Deploy to waku.sandbox
  - [ ] Coordinate with Infra Team about possible changes in CI behavior
  - [ ] Update waku.sandbox with [this deployment job](https://ci.infra.status.im/job/nim-waku/job/deploy-waku-sandbox/).

- [ ] Deploy to status.prod
  - [ ] Coordinate with Infra Team about possible changes in CI behavior
  - [ ] Ask Status admin to add a comment approving that this deployment to happen now.
  - [ ] Update status.prod with [this deployment job](https://ci.infra.status.im/job/nim-waku/job/deploy-status-prod/).

- [ ] Update infra config
  - [ ] Submit PRs into infra repos to adjust deprecated or changed arguments (review CHANGELOG.md for that release). And confirm the fleet can run after that. This requires coordination with infra team.

### Reference Links

- [Release process](https://github.com/logos-messaging/logos-delivery/blob/master/docs/contributors/release-process.md)
- [Release notes](https://github.com/logos-messaging/logos-delivery/blob/master/CHANGELOG.md)
- [Infra-role-nim-waku](https://github.com/status-im/infra-role-nim-waku)
- [Infra-waku](https://github.com/status-im/infra-waku)
- [Infra-Status](https://github.com/status-im/infra-status)
- [Jenkins](https://ci.infra.status.im/job/nim-waku/)
- [Fleets](https://fleets.waku.org/)
- [Harbor](https://harbor.status.im/harbor/projects/9/repositories/nwaku/artifacts-tab)
- [Kibana](https://kibana.infra.status.im/app/)
