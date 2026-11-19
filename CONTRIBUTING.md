# Contributing to SwiftXDS

Thank you for your interest in SwiftXDS. This guide explains how to propose a
change and what a change needs before it is merged. By participating, you
agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Before you start

- Search the existing issues, and open one before a large change so its scope
  can be agreed first.
- Report vulnerabilities privately, as described in [SECURITY.md](SECURITY.md).
- Never attach or commit messages or documents that contain patient data. Test
  fixtures must be synthetic or come from a public, redistributable source,
  with their origin recorded in the `README.md` of their `Fixtures` folder.

## Build and test

```sh
swift build --build-tests
swift test --skip-build --parallel
```

CI runs the tests on Linux, macOS, and iOS, on GitHub Actions and GitLab CI.

## What a change needs

| Requirement | Details |
| --- | --- |
| IHE reference | Cite the IHE ITI Technical Framework transaction and section that the change implements |
| Tests | Automated tests for every new claim; the in-memory registry of `SwiftXDSTestRegistry` plays the other actor |
| Platforms | The package builds and the tests pass on macOS, iOS, and Linux |
| Documentation | Update the README status table and the DocC articles in the same change; the site must build without warnings |
| No conformance claim | Conformance is claimed only after tests against third-party actors (NIST XDS Toolkit, Gazelle) |
| Compatibility | Source or behavior changes come with a migration note in the pull request; before 1.0, minor versions may break the API |

Build the documentation with:

```sh
Scripts/documentation/build.sh .build/documentation
```

## Style

- Follow the style of the surrounding code: naming, comment density, and
  idioms.
- Public API is documented with `///` comments.
- Keep commits focused. Write commit messages in English, following
  [Conventional Commits](https://www.conventionalcommits.org)
  (`feat(client): …`, `fix(mtom): …`). The changelog is generated from them
  with [git-cliff](https://git-cliff.org).

## Pull requests

Open pull requests against `main`. Describe what changes, why, the IHE
reference, and how it was verified. CI must pass before review.

By contributing, you agree that your contributions are licensed under the
[MIT License](LICENSE).
