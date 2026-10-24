# Releasing

Every build that reaches TestFlight has its own number, made of a version and a build: `0.2.0 (43)`.

- **Version**: `MARKETING_VERSION` in `project.yml`, three numbers, MAJOR.MINOR.PATCH. Only release-please
  changes it. Never edit it by hand.
- **Build**: `CURRENT_PROJECT_VERSION`, set by CI to the GitHub Actions run number on every upload. It only
  goes up and is never reused.

Apple allows at most three numbers in a version, so the build is the fourth place: `0.2.0 (43)` is build 43
of 0.2.0. No two uploads ever share a number.

## Every push to main

1. Write the commit as a Conventional Commit (`feat:`, `fix:`, `chore:` ...). release-please reads these.
2. Before pushing, know the number the build will get: the version in `project.yml`, plus the next run
   number of the TestFlight workflow.
3. Push. The TestFlight workflow uploads that version and build. Commits that only touch Markdown or the
   release-please files do not build.
4. When the TestFlight run passes, tag the commit `build/<version>-<build>` (for example `build/0.2.0-43`)
   and push the tag. Every build that shipped has a tag.

## Releasing a version

1. Merge the open `chore(main): release X.Y.Z` pull request that release-please keeps up to date. That
   creates the `vX.Y.Z` tag, the GitHub release and the CHANGELOG entry, and sets `project.yml` to X.Y.Z.
2. Builds after that are X.Y.Z with a higher build number, until the next release.
3. release-please picks the next version from the commits since the last release: below 1.0, `feat` raises
   the middle number and `fix` the last one.

Never create a `v*` tag by hand, and never set the version by hand.
