# Release Process

How to do releases.

For more context, see https://trunkbaseddevelopment.com/branch-for-release/

## How to do releases

### Prerequisites

- All issues under the corresponding release [milestone](https://github.com/waku-org/nwaku/milestones) have been closed or, after consultation, deferred to the next release.
- All submodules are up to date.
  > Updating submodules requires a PR (and very often several "fixes" to maintain compatibility with the changes in submodules). That PR process must be done and merged a couple of days before the release.

  > In case the submodules update has a low effort and/or risk for the release, follow the ["Update submodules"](./git-submodules.md) instructions.

  > If the effort or risk is too high, consider postponing the submodules upgrade for the subsequent release or delaying the current release until the submodules updates are included in the release candidate.

### Release types

- **Full release**: follow the entire [Release process](#release-process--step-by-step). 

- **Beta release**: skip just `6c` and `6d` steps from [Release process](#release-process--step-by-step).

- Choose the appropriate release process based on the release type:
  - [Full Release](../../.github/ISSUE_TEMPLATE/prepare_full_release.md)
  - [Beta Release](../../.github/ISSUE_TEMPLATE/prepare_beta_release.md)

### Release process ( step by step )

1. Checkout a release branch from master

    ```
    git checkout -b release/v0.X.0
    ```

2. Update `CHANGELOG.md` and ensure it is up to date. Use the helper Make target to get PR based release-notes/changelog update.

    ```
    make release-notes
    ```

3. Create a release-candidate tag with the same name as release and `-rc.N` suffix a few days before the official release and push it

    ```
    git tag -as v0.X.0-rc.0 -m "Initial release."
    git push origin v0.X.0-rc.0
    ```

    This will trigger a [workflow](../../.github/workflows/pre-release.yml) which will build RC artifacts and create and publish a GitHub release

4. Open a PR from the release branch for others to review the included changes and the release-notes

5. In case additional changes are needed, create a new RC tag

    Make sure the new tag is associated
    with CHANGELOG update.

    ```
    # Make changes, rebase and create new tag
    # Squash to one commit and make a nice commit message
    git rebase -i origin/master
    git tag -as v0.X.0-rc.1 -m "Initial release."
    git push origin v0.X.0-rc.1
    ```

    Similarly use v0.X.0-rc.2, v0.X.0-rc.3 etc. for additional RC tags.

6. **Validation of release candidate**

   6a. **Automated testing**
     - Ensure all the unit tests (specifically js-waku tests) are green against the release candidate.

   6b. **Waku fleet testing**
      - Start job on `waku.test` [Deployment job](https://ci.infra.status.im/job/nim-waku/), wait for completion of the job. If it fails, then debug it.
      - After completion, disable fleet so that daily ci not override your release candidate.
      - Verify at https://fleets.waku.org/ that the fleet is locked to the release candidate image.
      - Check if the image is created at [Harbor](https://harbor.status.im/harbor/projects/9/repositories/nwaku/artifacts-tab).
      - Search [Kibana logs](https://kibana.infra.status.im/app/discover) from the previous month (since the last release was deployed) for possible crashes or errors in `waku.test`.
        - Set time range to "Last 30 days" (or since last release).
        - Most relevant search query: `(fleet: "waku.test" AND message: "SIGSEGV")`.
        - Document any crashes or errors found.
      - If `waku.test` validation is successful, deploy to `waku.sandbox` using the same [Deployment job](https://ci.infra.status.im/job/nim-waku/).
      - Search [Kibana logs](https://kibana.infra.status.im/app/discover) for `waku.sandbox`: `(fleet: "waku.sandbox" AND message: "SIGSEGV")`.
      - Enable the `waku.test` fleet again to resume auto-deployment of the latest `master` commit.

   6c. **QA and DST testing**
     - Ask Vac-QA and Vac-DST to run their available tests against the release candidate; share all release candidates with both teams.

     > We need an additional report like [this](https://www.notion.so/DST-Reports-1228f96fb65c80729cd1d98a7496fe6f) specifically from the DST team.

   6d. **Status fleet testing**
     - Deploy release candidate to `status.staging`
     - Perform [sanity check](https://www.notion.so/How-to-test-Nwaku-on-Status-12c6e4b9bf06420ca868bd199129b425) and log results as comments in this issue.
       - Connect 2 instances to `status.staging` fleet, one in relay mode, the other one in light client.
       - 1:1 Chats with each other
       - Send and receive messages in a community
       - Close one instance, send messages with second instance, reopen first instance and confirm messages sent while offline are retrieved from store
     - Perform checks based on _end-user impact_.
     - Inform other (Waku and Status) CCs to point their instances to `status.staging` for a few days. Ping Status colleagues from their Discord server or [Status community](https://status.app) (not a blocking point).
     - Ask Status-QA to perform sanity checks (as described above) and checks based on _end user impact_; specify the version being tested.
     - Ask Status-QA or infra to run the automated Status e2e tests against `status.staging`.
     - Get other CCs' sign-off: they should comment on this PR, e.g., "Used the app for a week, no problem." If problems are reported, resolve them and create a new RC.
     - **Get Status-QA sign-off**, ensuring that the `status.test` update will not disturb ongoing activities.

7. Once the release-candidate has been validated, create a final release tag and push it.
We also need to merge the release branch back into master as a final step.

    ```
    git checkout release/v0.X.0
    git tag -as v0.X.0 -m "final release." (use v0.X.0-beta as the tag if you are creating a beta release)
    git push origin v0.X.0
    git switch master
    git pull
    git merge release/v0.X.0
    ```
8. Update `waku-rust-bindings`, `waku-simulator` and `nwaku-compose` to use the new release.

9. Create a [GitHub release](https://github.com/waku-org/nwaku/releases) from the release tag.

    * Add binaries produced by the ["Upload Release Asset"](https://github.com/waku-org/nwaku/actions/workflows/release-assets.yml) workflow. Where possible, test the binaries before uploading to the release.

### After the release

1. Announce the release on Twitter, Discord and other channels.
2. Deploy the release image to [Dockerhub](https://hub.docker.com/r/wakuorg/nwaku) by triggering [the manual Jenkins deployment job](https://ci.infra.status.im/job/nim-waku/job/docker-manual/).
  > Ensure the following build parameters are set:
  > - `MAKE_TARGET`: `wakunode2`
  > - `IMAGE_TAG`: the release tag (e.g. `v0.38.0`)
  > - `IMAGE_NAME`: `wakuorg/nwaku`
  > - `NIMFLAGS`: `--colors:off -d:disableMarchNative -d:chronicles_colors:none -d:postgres`
  > - `GIT_REF` the release tag (e.g. `v0.38.0`)

### Performing a patch release

1. Cherry-pick the relevant commits from master to the release branch

    ```
    git cherry-pick <commit-hash>
    ```

2. Create a release-candidate tag with the same name as release and `-rc.N` suffix

3. Update `CHANGELOG.md`. From the release branch, use the helper Make target after having cherry-picked the commits.

    ```
    make release-notes
    ```
    Create a new branch and raise a PR with the changelog updates to master.

4. Once the release-candidate has been validated and changelog PR got merged, cherry-pick the changelog update from master to the release branch. Create a final release tag and push it.

5. Create a [GitHub release](https://github.com/waku-org/nwaku/releases) from the release tag and follow the same post-release process as usual.

### Links

- [Release process](https://github.com/waku-org/nwaku/blob/master/docs/contributors/release-process.md)
- [Release notes](https://github.com/waku-org/nwaku/blob/master/CHANGELOG.md)
- [Fleet ownership](https://www.notion.so/Fleet-Ownership-7532aad8896d46599abac3c274189741?pvs=4#d2d2f0fe4b3c429fbd860a1d64f89a64)
- [Infra-nim-waku](https://github.com/status-im/infra-nim-waku)
- [Jenkins](https://ci.infra.status.im/job/nim-waku/)
- [Fleets](https://fleets.waku.org/)
- [Harbor](https://harbor.status.im/harbor/projects/9/repositories/nwaku/artifacts-tab)
- [Kibana](https://kibana.infra.status.im/app/)