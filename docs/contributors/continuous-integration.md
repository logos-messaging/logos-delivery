# Description

This document describes the continuous integration setup for `nim-waku`.

# Details

The CI setup exists on the Status.im Jenkins instance:

https://ci.infra.status.im/job/nim-waku/

It currently consists of four jobs:

* [manual](https://ci.infra.status.im/job/nim-waku/job/manual/) - For manually executing builds using parameters.
* [deploy-waku-test](https://ci.infra.status.im/job/nim-waku/job/deploy-waku-test/) - Builds every new commit in `master` and deploys to `waku.test` fleet.
* [deploy-waku-sandbox](https://ci.infra.status.im/job/nim-waku/job/deploy-waku-sandbox/) - Currently has no automatic trigger, and deploys to `waku.sandbox` fleet.

# Configuration

The main configuration file is [`Jenkinsfile.release`](../../ci/Jenkinsfile.release) in the `ci` folder.

Key part is the definition of `parameters`, most notably:

* `IMAGE_TAG` - Tag of the Docker image to push.
* `IMAGE_NAME` - Name of the Docker image to push.
* `LOGOSDELIVERY_IMAGE_NAME` - Name under which the same image is also pushed.
* `NIMFLAGS` - Nim compilation parameters.
* `GIT_REF` - Git reference to build from (branch, tag, commit...)

The use of `?:` [Elvis operator](http://groovy-lang.org/operators.html#_elvis_operator) plays a key role in allowing parameters to be changed for each defined job in Jenkins without it being overridden by the `Jenkinsfile` defaults after every job run.
```groovy
defaultValue: params.IMAGE_TAG ?: 'deploy-waku-test',
```

# Nightly CI

`.github/workflows/ci-daily.yml` runs every `ci.yml` job (`full: true`) every night and on manual dispatch. Its `notify` job reports through [`scripts/nightly_notify.sh`](../../scripts/nightly_notify.sh), only when the result changes and only for runs of the default branch:

* first red night: opens a `nightly-failure` + `infra` issue listing the failed jobs, and posts to Discord
* each further red night: comments on that issue and posts with the day count
* first green night: posts and closes the issue
* green after green: nothing

Settings:

* `DISCORD_WEBHOOK_URL` secret - the channel the posts go to. Without it only the issue is updated.
* `NIGHTLY_OWNER` in `ci-daily.yml` - the GitHub login the tracking issue is assigned to. The owner is `Ivansete-status`. GitHub notifies the owner of the assignment and of each further comment, so the Discord posts mention no role.
