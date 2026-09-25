# Releasing Boomkat

`VERSION` is the release version. The CLI embeds the same value in
`CLI_VERSION` in `cli/boomkat.c3`. `bk_version()` in the C ABI embeds it too.
`scripts/check_release_version.py` checks all three values and, on a tag build,
requires the Git tag to equal `v<VERSION>`.

The release workflow accepts `v0.0*` tags. A tag push starts the version check,
all release gates, and native build jobs. GitHub publishes the release only when
every job passes. A manual run builds downloadable workflow artifacts without
publishing a GitHub release.

## Prepare a tag

1. Update `VERSION`, `CLI_VERSION`, and `bk_version()` to the same version.
2. Run `python3 scripts/check_release_version.py --tag v<VERSION>` and the
   relevant local tests.
3. Commit the version change, then create and push the matching annotated tag.

For the committed `0.0.0` version, the commands are:

```sh
python3 scripts/check_release_version.py --tag v0.0.0
git tag -a v0.0.0 -m 'Boomkat v0.0.0'
git push origin v0.0.0
```

Tag pushes publish externally. Review the version, commit, and release notes
before pushing a tag.

## What the workflow checks

The Linux validation job builds the CLI, embedding archive, test262 runner, and
heap verifier. It runs the C embedding smoke test, local suite, TypeScript
conformance, full test262 zero-failure gate, heap verifier shard, JavaScript
library corpus, and TypeScript library corpus. The build jobs also run a CLI
version and stdin smoke check on both normal and slim binaries.

## Release assets

| Platform | Build method | Archive |
|---|---|---|
| Linux x64 | native Ubuntu runner | `.tar.gz` |
| Linux arm64 | native Ubuntu arm64 runner | `.tar.gz` |
| macOS arm64 | native macOS runner | `.tar.gz` |
| macOS x64 | cross compile on macOS arm64; run under Rosetta | `.tar.gz` |
| Windows x64 | native Windows runner | `.zip` |

Each platform produces normal and slim CLI archives, plus a static library
archive with `boomkat.h` and a C hello-world example. Every archive includes
`LICENSE`.
`SHA256SUMS.txt` on the GitHub release covers every archive.
The packaging script is `scripts/package_release.py`; it is also usable locally.
Windows is best effort until its first GitHub runner build verifies the full
compiler, C dependency, and linker path.
