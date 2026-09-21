<p align="center">English | <a href="https://docs.seedex.net/ru/developer-guide/contributing">Русский</a></p>

# Contributing to Seedex Agent

Bug reports, suggestions, and pull requests are welcome. This page describes how to report a problem and how to get a change merged.

## Report a bug

Open an issue with:

* The Ubuntu version.
* The output of `sdx version` and `sdx`, and the log of the service involved.
* What you did, what you expected, and what happened instead.

Remove keys, tokens, certificate fingerprints, and public IP addresses from the output before you post it.

## Suggest a change

For a small fix, open a pull request. For a new feature or a change in behavior, open an issue first so that the approach is agreed on before you spend time on it.

## Set up

You need Go 1.22 for the build of the Link API, shfmt 3.13 and shellcheck 0.11 for the lint, and a server running Ubuntu 24.04 or later to try a build. The [developer guide](https://docs.seedex.net/developer-guide/seedex-agent) describes the project structure, the build, and how to install a build on a server.

## Code style

* The shell code is `bash` and runs on the server only.
* Formatting is what shfmt and gofmt produce and what `.editorconfig` sets: tabs, lines up to 100 characters.
* Every shell file passes shellcheck with the rules in `.shellcheckrc`. Don't add `# shellcheck disable` to silence a warning that has a fix.
* The Link API in `link/` is Go with the standard library only. Keep it that way: it's one binary that the installer downloads.
* Match the surrounding code: naming, comment density, and the way errors are reported.

## Lint and test

Run the lint before you push:

```sh
make lint
```

It runs shfmt and shellcheck over the shell files, and `gofmt` and `go vet` over the Go code. CI runs the same target on every push and pull request.

There is no automated test suite. Build with `make build`, install on a server with `bash install.sh files`, and exercise the change: the affected `sdx` commands, and a paired router if the change touches what the Link API serves. Say in the pull request what you tested.

## Commits

* One topic per commit. Fold follow-up fixes into the commit they fix rather than adding a second one.
* The subject is lowercase, in the present tense, and starts with the area: `proxy: start without protocols is a no-op`, `link: run sdx over the API`, `vpn: protocol modules, wg and awg`. Areas are the services (`vpn`, `proxy`, `link`), `install`, `lint`, and `docs`.
* Don't change `version`. Maintainers bump it with `make bump` when they release; a `v*` tag builds the release.

## Pull requests

* Target `main` and keep the change small enough to review in one sitting.
* Describe what the change does and why. Link the issue if there is one.
* A change in user-facing behavior updates the documentation too: the README in this repository and the pages in [seedex-docs](https://github.com/aggnostos/seedex-docs), where the English and Russian pages mirror each other.
* CI must pass.

## License

Contributions are accepted under the [AGPL-3.0](LICENSE) license of the project. The Seedex name and logo are covered by the [trademark policy](TRADEMARK.md), not by the license.
