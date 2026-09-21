<p align="center">English | <a href="https://docs.seedex.net/ru/developer-guide/seedex-agent#участие">Русский</a></p>

# Contributing to Seedex Agent

Bug reports, suggestions, and pull requests are welcome. This page describes how to report a problem and how to get a change merged.

## Report a bug

Open an issue with:

* The Ubuntu version.
* The output of `sdx version` and `sdx`, plus the log of the service involved.
* What you did, what you expected, and what happened instead.

Strip keys, tokens, certificate fingerprints, and public IP addresses from the output before posting it.

## Suggest a change

A small fix goes straight to a pull request. A new feature or a change in behavior starts with an issue, so that the approach is agreed on before you spend time on it.

## Set up

The Link API build needs Go 1.22. The lint needs shfmt 3.13 and shellcheck 0.11. Trying a build needs a server on Ubuntu 24.04 or later. The [developer guide](https://docs.seedex.net/developer-guide/seedex-agent) describes the project structure, the build, and how to install a build on a server.

## Code style

* The shell code is `bash` and runs on the server only.
* Formatting is what shfmt and gofmt produce, as `.editorconfig` sets it: tabs, lines up to 100 characters.
* Every shell file passes shellcheck with the rules in `.shellcheckrc`. Fix the warning rather than adding `# shellcheck disable`.
* The Link API in `link/` is Go with the standard library only. Keep it that way: it is one binary that the installer downloads.
* Match the surrounding code: naming, comment density, and the way errors are reported.

## Check

Run the lint before you push:

```sh
make lint
```

It runs shfmt and shellcheck over the shell files. The Go code goes through `gofmt` and `go vet`. CI runs the same target on every push and pull request.

There is no automated test suite. Build with `make build`, install on a server with `bash install.sh files`, and exercise the change: the affected `sdx` commands, plus a paired router if the change touches what the Link API serves. Say in the pull request what you tested.

## Commits

* One topic per commit. A follow-up fix goes into the commit it fixes, not into a second one.
* The subject is lowercase, present tense, and prefixed with the area: `proxy: start without protocols is a no-op`, `link: run sdx over the API`, `vpn: protocol modules, wg and awg`. Areas: the services (`vpn`, `proxy`, `link`), `install`, `lint`, and `docs`.
* Leave `version` alone. Maintainers bump it with `make bump` at release time; a `v*` tag builds the release.

## Pull requests

* Target `main` and keep the change small enough to review in one sitting.
* Describe what the change does and why. Link the issue if there is one.
* A change in user-facing behavior also updates the documentation: the README here and the pages in [seedex-docs](https://github.com/aggnostos/seedex-docs), where the English page mirrors the Russian one.
* CI must pass.

## License

Contributions are accepted under the project's [AGPL-3.0](LICENSE) license. The Seedex name and logo are covered by the [trademark policy](https://docs.seedex.net/trademark), not by the license.
