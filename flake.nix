{
  description = "CodeTracer BEAM materialized trace recorder (Erlang and Elixir)";

  inputs = {
    nixos-modules.url = "github:metacraft-labs/devops-modules";
    nixpkgs.follows = "nixos-modules/nixpkgs-unstable";
    flake-parts.follows = "nixos-modules/flake-parts";
    git-hooks.follows = "nixos-modules/git-hooks-nix";

    # The recorder crate path-depends on ../codetracer-trace-format (see
    # Cargo.toml), and codetracer_trace_writer_nim's build.rs compiles the
    # Nim FFI library from ../codetracer-trace-format-nim. Neither sibling is
    # inside `src = ./.`, so the package build seeds both from these inputs.
    #
    # THE REVISION THAT COUNTS IS repro.lock's, NOT flake.lock's. CI clones
    # each sibling at the commit this repo's repro.lock pins (clone-siblings)
    # and builds with
    #   --override-input codetracer-trace-format path:../codetracer-trace-format
    #   --override-input codetracer-trace-format-nim path:../codetracer-trace-format-nim
    # so the locked flake revisions below are only the fallback for a bare
    # `nix build` outside the workspace. `/agents`, as in codetracer's flake:
    # the trace format this recorder writes is integrated there and reaches
    # `dev` with the next promotion.
    codetracer-trace-format = {
      url = "github:metacraft-labs/codetracer-trace-format/agents";
      flake = false;
    };
    codetracer-trace-format-nim = {
      url = "github:metacraft-labs/codetracer-trace-format-nim/agents";
      flake = false;
    };
    # The Nim packages codetracer-trace-format-nim `requires` (stew,
    # results). `nimble install` cannot reach the network inside the build
    # sandbox, so their sources go on Nim's path directly. Same sources as
    # codetracer-trace-format-nim's own flake.
    nim-stew = {
      url = "github:status-im/nim-stew";
      flake = false;
    };
    nim-results = {
      url = "github:arnetheduck/nim-results";
      flake = false;
    };
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      flake-parts,
      git-hooks,
      ...
    }:
    let
      cargoToml = builtins.fromTOML (builtins.readFile ./Cargo.toml);
      # The sibling sources default to this flake's inputs; a consumer that
      # has its own checkouts (or its own pins) passes them instead.
      mkBeamRecorderPackage =
        {
          pkgs,
          codetracer-trace-format ? inputs.codetracer-trace-format,
          codetracer-trace-format-nim ? inputs.codetracer-trace-format-nim,
          nim-stew ? inputs.nim-stew,
          nim-results ? inputs.nim-results,
        }:
        pkgs.rustPlatform.buildRustPackage {
          pname = "codetracer-beam-recorder";
          version = cargoToml.package.version;

          src = ./.;
          cargoLock.lockFile = ./Cargo.lock;

          # Cargo resolves `../codetracer-trace-format/...` against the
          # unpacked source, i.e. next to `$sourceRoot` in the build dir.
          postUnpack = ''
            ln -s ${codetracer-trace-format} "$sourceRoot/../codetracer-trace-format"
          '';

          # codetracer_trace_writer_nim/build.rs compiles the Nim FFI library.
          # `nimble install --depsOnly` would need the network, so it is
          # skipped and the `requires` packages are put on Nim's path instead.
          CODETRACER_TRACE_FORMAT_NIM_DIR = "${codetracer-trace-format-nim}";
          CODETRACER_TRACE_FORMAT_NIM_SKIP_NIMBLE_INSTALL = "1";
          CODETRACER_TRACE_FORMAT_NIM_EXTRA_PATHS = "${nim-stew}:${nim-results}";

          # The check phase runs the unit tests only. tests/cli_test.rs drives
          # real erlc / elixir / mix / rebar3 builds (some fetching from Hex),
          # which the sandbox has neither the toolchain nor the network for;
          # it runs in CI's `test` job, inside the dev shell (`just test`).
          cargoTestFlags = [ "--bins" ];

          nativeBuildInputs = with pkgs; [
            capnproto
            nim
            pkg-config
          ];
          buildInputs = with pkgs; [
            zstd
          ];

          meta = {
            description = "CodeTracer BEAM materialized trace recorder (Erlang and Elixir)";
            homepage = "https://github.com/metacraft-labs/codetracer-beam-recorder";
            license = pkgs.lib.licenses.mit;
            mainProgram = "codetracer-beam-recorder";
          };
        };
      # Deprecated alias retained for one release cycle so downstream consumers
      # that still reference the Elixir-only naming continue to work.
      mkElixirRecorderPackage = mkBeamRecorderPackage;
    in
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      flake.lib.mkBeamRecorderPackage = mkBeamRecorderPackage;
      # Deprecated: prefer mkBeamRecorderPackage. Retained for one release cycle.
      flake.lib.mkElixirRecorderPackage = mkElixirRecorderPackage;

      perSystem =
        {
          self',
          pkgs,
          system,
          ...
        }:
        let
          preCommit = self.checks.${system}.pre-commit-check;
          # The committed `.pre-commit-config.yaml` is what the pre-commit hook
          # runs, with the flake's pre-commit: the flake provides the tools, the
          # committed config provides the rules. git-hooks.nix's own installer
          # refuses to replace a committed config and then installs nothing.
          installGitHooks = ''
            bash ${./scripts/install-git-hooks.sh} ${pkgs.lib.getExe preCommit.config.package} || exit $?
          '';
          # The hooks are installed into
          # `git rev-parse --show-toplevel` of the directory the shell is entered
          # from, so `nix develop /path/to/this-repo` run inside another checkout
          # would plant this repository's hooks there. `ownRepoOnly` runs a snippet
          # only when that toplevel is this repository, recognised by a `flake.nix`
          # identical to the one this shell was evaluated from; anything it cannot
          # establish counts as another repository, so it fails safe.
          # tests/test_dev_shell_writes_nothing_elsewhere.sh
          ownRepoOnly = script: ''
            _own_repo_root="$(${pkgs.git}/bin/git rev-parse --show-toplevel 2>/dev/null || true)"
            if [ -n "$_own_repo_root" ] && [ -f "$_own_repo_root/flake.nix" ] \
              && [ "$(${pkgs.coreutils}/bin/sha256sum "$_own_repo_root/flake.nix" | ${pkgs.coreutils}/bin/cut -d' ' -f1)" \
                = "${builtins.hashFile "sha256" ./flake.nix}" ]; then
            ${script}
            # A clone where git-hooks.nix's own installer once ran keeps its RELATIVE
            # core.hooksPath `.git/hooks`, in the config every worktree shares. A linked
            # worktree cannot resolve it (there `.git` is a file), so git silently runs
            # no hooks there. Point it at the common hooks directory instead.
            if [ "$(${pkgs.git}/bin/git config --local --get core.hooksPath 2>/dev/null)" = .git/hooks ]; then
              ${pkgs.git}/bin/git config --local core.hooksPath "$(${pkgs.git}/bin/git rev-parse --path-format=absolute --git-common-dir)/hooks"
            fi
            # `pre-commit install` (and git-hooks.nix's installer, where it once ran)
            # moves each Reprobuild hook dispatcher aside to `<hook>.legacy` and puts
            # its shim in the slot, so the managed hook (for pre-push, the publication
            # gate) runs only by accident. Put the dispatcher back and chain the shim as
            # `<hook>.repro-local`, which the dispatcher runs: the layout
            # `repro hooks ensure --vcs` produces.
            _hooks="$(${pkgs.git}/bin/git rev-parse --path-format=absolute --git-path hooks 2>/dev/null || true)"
            for _legacy in "$_hooks"/*.legacy; do
              [ -f "$_legacy" ] && grep -q 'reprobuild hook dispatcher' "$_legacy" || continue
              _slot="''${_legacy%.legacy}"
              if [ -f "$_slot" ] && grep -q 'reprobuild hook dispatcher' "$_slot"; then
                rm -f "$_legacy"
              elif [ ! -e "$_slot" ] || grep -Eq '^# File generated by (pre-commit|prek)' "$_slot"; then
                if [ -f "$_slot.repro-local" ] && ! grep -Eq '^# File generated by (pre-commit|prek)' "$_slot.repro-local"; then
                  echo "git-hooks: $_slot.repro-local is your own hook; run 'repro hooks ensure --vcs' to reconcile." >&2
                  continue
                fi
                if [ -e "$_slot" ]; then mv -f "$_slot" "$_slot.repro-local"; fi
                mv -f "$_legacy" "$_slot"
              else
                echo "git-hooks: $_slot is not a pre-commit shim; run 'repro hooks ensure --vcs' to reconcile." >&2
              fi
            done
            unset _hooks _legacy _slot
            fi
            unset _own_repo_root
          '';
        in
        {
          checks.pre-commit-check = git-hooks.lib.${system}.run {
            src = ./.;
            hooks = {
              lint = {
                enable = true;
                name = "just lint";
                entry = "just lint";
                language = "system";
                pass_filenames = false;
                extraPackages = with pkgs; [
                  cargo
                  clippy
                  just
                  nixfmt
                  rebar3
                  rustc
                  rustfmt
                  shellcheck
                  shfmt
                ];
              };
              check-added-large-files.enable = true;
              check-merge-conflicts.enable = true;
            };
          };

          devShells.default = pkgs.mkShell {
            packages =
              with pkgs;
              [
                cargo
                capnproto
                clippy
                elixir
                erlang
                just
                jq
                # tests/verify-ci-sibling-provisioning.sh reads the workflows
                # (YAML) and repro.lock (TOML) with it.
                yq-go
                # nim + nimble are required by the
                # ``codetracer_trace_writer_nim`` crate's build.rs --
                # without them, ``cargo build`` aborts with::
                #   failed to run `nimble` -- it ships with the Nim
                #   toolchain and must be on PATH alongside `nim`
                # (cross-repo run 27678456790).  Match the
                # solana/leo recorder flakes which keep these in
                # the devShell for the same reason.
                nim
                nimble
                nixfmt
                pkg-config
                prek
                rebar3
                rustc
                rustfmt
                shellcheck
                shfmt
                zstd
              ]
              ++ preCommit.enabledPackages;

            # `cargo <subcommand>` looks for `cargo-<subcommand>` in
            # `$CARGO_HOME/bin` BEFORE it searches PATH. On any machine with
            # rustup — including self-hosted macOS runners — that directory
            # holds rustup's proxies, so `cargo fmt` and `cargo clippy` run
            # rustup's `cargo-fmt` / `cargo-clippy` instead of the rustfmt and
            # clippy above, and fail with "'cargo-fmt' is not installed for the
            # toolchain".
            #
            # The shell therefore gets its own CARGO_HOME with no `bin/`, so
            # subcommand lookup falls through to PATH. `registry/` and `git/`
            # are symlinks to the real CARGO_HOME, and so are its config and
            # credentials when present: the download cache is shared, and only
            # the proxy directory is left behind.
            shellHook = ownRepoOnly installGitHooks + ''
              _beam_real_cargo_home="''${CARGO_HOME:-$HOME/.cargo}"
              _beam_cargo_home="''${XDG_CACHE_HOME:-$HOME/.cache}/codetracer-beam-recorder/cargo-home"
              if [ "$_beam_real_cargo_home" != "$_beam_cargo_home" ]; then
                mkdir -p "$_beam_cargo_home" \
                  "$_beam_real_cargo_home/registry" "$_beam_real_cargo_home/git"
                # Re-pointed on every entry, so a changed CARGO_HOME is followed
                # rather than left sharing the previous one's cache. Only a link
                # is ever replaced; a real file placed here is left alone.
                for _beam_entry in registry git config.toml credentials.toml; do
                  if [ -e "$_beam_real_cargo_home/$_beam_entry" ] &&
                    { [ -L "$_beam_cargo_home/$_beam_entry" ] ||
                      [ ! -e "$_beam_cargo_home/$_beam_entry" ]; }; then
                    ln -sfn "$_beam_real_cargo_home/$_beam_entry" "$_beam_cargo_home/$_beam_entry"
                  fi
                done
                export CARGO_HOME="$_beam_cargo_home"
              fi
              unset _beam_real_cargo_home _beam_cargo_home _beam_entry
            '';
          };

          packages.codetracer-beam-recorder = mkBeamRecorderPackage { inherit pkgs; };
          # Deprecated alias retained for one release cycle.
          packages.codetracer-elixir-recorder = self'.packages.codetracer-beam-recorder;
          packages.default = self'.packages.codetracer-beam-recorder;
        };
    };
}
