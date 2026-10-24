# Releasing

Every build that reaches TestFlight is named `X.Y.Z (N)`, for example `0.2.1 (45)`.

- **Version** `X.Y.Z`: `MARKETING_VERSION` in `project.yml`, three numbers, MAJOR.MINOR.PATCH. Only
  release-please changes it.
- **Build** `N`: the run number of the TestFlight workflow (`CURRENT_PROJECT_VERSION`, set by CI). It only
  goes up and is never reused.

The build number is shown beside the version and is never part of it.

## Every change that ships is its own release

A push to main is read as Conventional Commits.

- If it holds a `feat`, `fix` or `perf` commit (or a breaking change), the Release workflow makes a new
  version straight away. It opens the release pull request, merges it, tags `vX.Y.Z`, writes the GitHub
  release and the CHANGELOG entry, and starts the TestFlight workflow on that tag.
- TestFlight builds it as `X.Y.Z (N)`. The `vX.Y.Z` release tag is the only tag a build gets. The older
  `build/X.Y.Z-N` tags (builds up to 44) stay as history; no new ones are made.
- A push with only `ci`, `docs`, `chore`, `refactor`, `test`, `build` or `style` commits makes no release
  and no build.
- Several commits in one push make one release.

## The next number

- Below 1.0, `fix` or `perf` raises the last number (0.2.0 to 0.2.1).
- `feat` or a breaking change (`feat!:`) raises the middle number and resets the last (0.2.1 to 0.3.0).
- A push with both takes the bigger step.
- The build is the TestFlight workflow's latest run number plus one.
- Before pushing, work out both, for example "this push makes 0.2.1 (45)".

## Before and after

| Before | Now |
| --- | --- |
| 0.2.0 (39) | 0.2.0 (44), everything up to the doubles release |
| 0.2.0 (40) | 0.2.1 (45), the next fix |
| 0.2.0 (41) | 0.3.0 (46), the next feature |
| 0.2.0 (42) | |
| 0.2.0 (43) | |

Before, five builds with different changes all read 0.2.0. Now each shipped change gets its own version.

## Building again without a change

Only when an upload failed. In Actions, pick TestFlight, then Run workflow, and choose the latest `vX.Y.Z`
tag (or run `gh workflow run testflight.yml --ref vX.Y.Z`). It repeats that version with the next build number,
so any real change ships as the next release instead.

## If a run fails

- Release run: re-run it from the Actions tab. It tags a merged release pull request first, then starts the
  build.
- TestFlight run that hit an Apple network blip: re-run the failed job.
- A real defect ships as the next fix release.

## Never

- Edit `MARKETING_VERSION` by hand.
- Create `v*` tags, `build/*` tags or GitHub releases by hand.
- Put the build number into the version.
