# check.sh runs nixfmt --check (issue #43)

Pull request #38 passed Inspector and then failed CI twice on `nixfmt
--check`: `check.sh` ran shellcheck and the bash suites but no formatter,
so a formatting miss was invisible until a pull request existed.
`Dockerfile.inspector` now carries nixfmt and `check.sh` runs it. The
durable facts behind the shape of that change:

- **A missing nixfmt is red, not skipped.** `check.sh` hard-fails with a
  message when `command -v nixfmt` finds nothing. A skip-with-warning
  would have reproduced the exact hole being closed - "no formatter
  present" and "formatter found nothing" would both read as green. Every
  Nix-managed host already has nixfmt via `modules/core.nix`, and
  Inspector's image now does too, so the hard fail only bites a box that
  has neither (the work host, or a worker's throwaway checkout).

- **`Dockerfile.inspector` must stay toolchain-only - `FROM`, `RUN`,
  `USER`, `ENV` and nothing that reads the build context.** Inspector
  tags the image by the Dockerfile's content plus each `FROM`'s resolved
  image ID, and rebuilds a Dockerfile containing `COPY`, `ADD` or `RUN
  --mount` on *every single run*; a toolchain-only one builds once. That
  is why nixfmt is installed by a `RUN` rather than copied in from a
  multi-stage builder, even though a `COPY --from=` stage would have been
  a smaller image.

- **nixfmt's own GitHub release cannot be used here: it is x86_64-only.**
  Each release ships exactly one asset, a static binary its release
  workflow builds from `packages.nixfmt-static` on an x86_64 runner.
  `cimg/base` is published for amd64 *and* arm64, and Inspector passes no
  `--platform` - it takes whatever the local daemon defaults to, which is
  arm64 on an Apple Silicon Mac. A downloaded release binary would have
  worked on `home-linux` and failed with an exec-format error on both
  Macs. nixpkgs builds nixfmt for both architectures, hence
  `nix build nixpkgs#nixfmt`.

- **The formatter has to be baked in and reachable by an arbitrary uid,
  because of two things Inspector does at run time.** It runs the
  container with `--network none` (its README: "there is no way to ask
  for one"), so CI's `nix shell nixpkgs#nixfmt --command nixfmt --check`
  is not an option - nothing can be fetched. And it runs the container as
  the invoking *host* user via `docker run --user <uid>:<gid>`, so the
  binary must not live anywhere user-private: it is reached through
  `/usr/local/bin/nixfmt` (on every PATH, whatever a login shell does)
  pointing into the world-readable store. `nix` itself is deliberately
  unusable at check time anyway - the container install uses `--init
  none`, which per Determinate's own documentation leaves Nix root-only.

- **`--out-link /opt/nixfmt` is load-bearing.** `nix build` registers the
  out-link as a garbage-collection root; with `--no-link` the store path
  would be collectable out from under the `/usr/local/bin` symlink. The
  `test -x` guard next to it is there because `ln -s` succeeds against a
  target that does not exist, so a build that produced nothing would
  otherwise still produce a green image and fail later, at check time.

- **Both sides resolve the same package reference, `nixpkgs#nixfmt`, but
  not at the same moment.** CI resolves it on every run;
  the image resolves it when the Dockerfile last changed. They can
  therefore drift by a nixfmt release, and nixfmt releases do change
  output. The remedy when that happens is to touch `Dockerfile.inspector`
  so Inspector rebuilds; pinning one side to a revision (the repo's
  `flake.lock` nixpkgs, say) would make the drift permanent rather than
  temporary, since that pin tracks a release branch while CI's registry
  entry tracks unstable.

- **A nixfmt failure surfaces as exit 123, not 1.** The check is a
  pipeline into `xargs`, which reports 123 when the command it ran exited
  1-125. `ci-floor.yml`'s step has the identical shape, and both only ever
  need "non-zero", so nothing depends on the number - but do not write a
  test that asserts 1.

## What `ci-floor.yml` still checks and `check.sh` still does not

Worth knowing, because each gap is the same shape as the one this closed -
something a pull request can fail on after Inspector was green:

- `sh work/bootstrap.test.sh`, the only `macos-latest` suite. Left out on
  purpose: the point of running it on macOS is that its `#!/bin/sh`
  shebang is a genuinely different shell there (bash in POSIX mode) than
  in a Linux container (dash), so running it in Inspector's image would
  not be the same check, and could fail for reasons the real host never
  has.
- The five eval-only `nix eval` steps, one per host. Out of reach rather
  than declined: evaluating any host fetches this flake's inputs, and the
  container has no network. Baking the whole input closure into the image
  to make them possible is a much larger change than issue #43.
- `install.container-test.yml`'s container rehearsal, which needs Docker -
  explicitly CI-only, as issue #43 says.

Neither `check.sh` nor `ci-floor.yml` shellchecks `check.sh` itself or
`modules/*.sh`; that gap is in both halves equally, so it is not of this
shape, but it is still a gap.
