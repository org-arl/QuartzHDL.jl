# Contributing to QuartzHDL.jl

Bug reports, feature requests, ideas, documentation improvements, bug fixes and new features are all welcome — including improvements to this document.

## Getting started

We assume familiarity with git, GitHub, Markdown and Julia. If you need to brush up on these, here are some good starting points:

* [GitHub](https://docs.github.com/en/get-started/quickstart/set-up-git)
* [Markdown](https://guides.github.com/features/mastering-markdown/)
* [Julia](https://julialang.org/learning/)

We haven't adopted a formal code of conduct, but there is an implicit expectation that all of us are professional, respectful of differing opinions and viewpoints, empathetic and kind, and open to giving and gracefully accepting constructive feedback. By contributing, you accept to abide by this.

## Bug reports, feature requests and discussions

**Bug reports** are what make a package reliable. A good one lets others reproduce the problem: the design, the call, what you expected and what you got. See [this article](https://stackoverflow.com/help/mcve) on writing a minimal example. Try the code on `master` first to confirm the bug is still there, and search the existing issues before [filing a new one](https://github.com/org-arl/QuartzHDL.jl/issues/new).

**Feature requests** go in as issues too. Say what you are trying to build and why the package gets in the way; a use case is worth more than a design.

**Discussions** are for everything else: questions, things you have built, ideas that are not concrete enough to be a feature request yet. [Open one](https://github.com/org-arl/QuartzHDL.jl/discussions).

## Code and documentation

1. Fork the repository and clone your fork.
2. Branch from `master`. Keep the branch name short and lowercase, with hyphens, and keep each branch to one issue or one related set of changes.
3. Make your changes. Code lives in `src/`, tests in `test/`, and the manual in `qdocs/` — Quarto sources rendered into `docs/` with `cd qdocs && make docs`. Rendering needs [Quarto](https://quarto.org) and a Julia environment for `qdocs/`; the `Makefile` says how.
4. Add tests. A bug fix gets a test that fails before the fix; a feature gets tests for what it does. Anything that touches the compiler or the simulator needs a co-simulation test (`cosim`), since the point of the package is that the Julia model and the Verilog agree — see the manual's *Tests and CI* chapter.
5. Run the test suite, `julia --project -e 'using Pkg; Pkg.test()'`, with [Icarus Verilog](https://steveicarus.github.io/iverilog/) on the path so the co-simulation tests run rather than being skipped.
6. Commit with a [good message](#commit-messages), push, and raise a pull request against `master`. Say what changed and link the issue it addresses. A draft PR is fine while work is in progress.
7. A maintainer reviews the PR; once the review is resolved it is merged and goes into the next release.

## Commit messages

Each commit message has a **header** and, where the header cannot carry the why, a **body**:

```
type(scope): summary

body
```

The summary is imperative and present tense, lowercase, with no trailing period, and about 50 characters; body lines wrap at 80. Reference the issue where there is one. A commit that breaks backward compatibility starts its body with `BREAKING CHANGE:`.

**Types**: `feat` (a new feature), `fix` (a bug fix), `docs` (documentation only), `test` (tests only), `perf` (a performance improvement), `refactor` (neither a feature nor a fix), `style` (formatting), `chore` (build, CI, housekeeping), `revert` (reverts a commit; give its SHA).

**Scopes**: `core` (the language: structs, blocks, values, hierarchy), `sim` (benches, simulation, links), `emitters` (Verilog, constraints, models, VCD, co-simulation), `library` (the ready-made parts), `docs` (the manual), `test` (the test suite). Several scopes may be listed with commas; when everything is touched, leave the scope out.

Examples:

```
fix(emitters): a clock mux switch is not an edge in the behavioural model
```
```
feat(library): add an SPI slave that answers each command byte

A closure given with `on` sees every byte the master sends and returns the
reply the slave shifts out next, so a register map is a few lines.
```

## Coding standards

Good Julia practice applies: the [Julia style guide](https://docs.julialang.org/en/v1/manual/style-guide/), the [performance tips](https://docs.julialang.org/en/v1/manual/performance-tips/) and the [documentation guidelines](https://docs.julialang.org/en/v1/manual/documentation/). In particular:

- Two-space indentation, no tabs. Blank lines separate sections; excess whitespace does not.
- Type names are `CamelCase`; functions and variables are lowercase, with an underscore only where the words would be hard to read run together.
- Descriptive names, no abbreviations unless common (`count`, not `cnt`). Single-letter index variables are fine.
- Code should explain itself. A comment says what the code cannot: the reason, the reference, the invariant. Comments that restate the code go stale and mislead, so they are left out; comments that could go out of sync with the code are avoided.
- Delete unused code rather than commenting it out; git remembers.
- Every public type and function has a docstring with its signature.
- The design runs in a loop: keep it type-stable and allocation-free where it runs per clock. The `inference` testset checks the paths that matter.
- When in doubt, follow the surrounding code, or [ask](https://github.com/org-arl/QuartzHDL.jl/discussions).

## Acknowledgments

This document follows the one in [UnderwaterAcoustics.jl](https://github.com/org-arl/UnderwaterAcoustics.jl), which in turn drew on [xarray](http://xarray.pydata.org/en/stable/contributing.html), [GitHub](https://github.com/github/docs/blob/main/CONTRIBUTING.md) and the [Angular commit format](https://gist.github.com/brianclements/841ea7bffdb01346392c).
