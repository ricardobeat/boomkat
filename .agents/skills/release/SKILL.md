---
name: release
description: Cut a Boomkat release: draft CHANGELOG.md entries from git history, get approval, bump versions, tag, and push to trigger the release workflow. Use when asked to release, tag, or prepare a version.
disable-model-invocation: true
argument-hint: <version>
---

# Release

Releases are cut locally. Pushing the `v<version>` tag starts
`.github/workflows/release.yml`, which checks the version and changelog, waits
for CI on the release commit, builds every platform, and publishes the GitHub
release with the `CHANGELOG.md` section as its body.

## Steps

1. **Preflight.** The tree must be clean, the branch `main`, and level with
   `origin/main`. Check CI on HEAD with
   `gh run list --workflow ci.yml --commit "$(git rev-parse HEAD)"`; stop if it
   has not passed.
2. **Draft the entries.** Read `git log --format=%s $(git describe --tags --abbrev=0)..HEAD`
   and write the user-visible changes under `## [Unreleased]` in `CHANGELOG.md`.
   - A few short bullets: new builtins and language features, spec conformance,
     C API and CLI changes, build profiles and flags, notable size or speed work,
     architecture changes.
   - Leave out refactors, comment passes, test and benchmark bookkeeping, and
     reverted work. Merge a run of related commits into one bullet.
   - Read the diff when a subject does not say what changed.
3. **Ask for approval.** Show the new section and the version, and stop. Do not
   commit until the user approves; apply their edits first.
4. **Bump and tag.** Run `just release <version>`. It rolls `Unreleased` under
   `## [<version>] - <date> · <n> commits`, bumps `VERSION`, `CLI_VERSION` and
   `bk_version()`, commits "Release v<version>", and creates the annotated tag.
5. **Ask before pushing.** The push is the point of no return: it starts public
   builds. After the user confirms, run `git push origin main v<version>`.
6. **Follow the workflow.** `gh run watch` the Release run, then check
   `gh release view v<version>` for the assets and the changelog body. Report
   failures with the log excerpt; do not retag without asking.

If the release commit needs a fix before the push, undo it with
`git tag -d v<version> && git reset --hard HEAD~1`, and tell the user first.
