{
  description = "CodeTracer BEAM materialized trace recorder (Erlang and Elixir)";

  inputs = {
    nixos-modules.url = "github:metacraft-labs/devops-modules";
    nixpkgs.follows = "nixos-modules/nixpkgs-unstable";
    flake-parts.follows = "nixos-modules/flake-parts";
    git-hooks.follows = "nixos-modules/git-hooks-nix";
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
      mkBeamRecorderPackage =
        {
          pkgs,
        }:
        pkgs.rustPlatform.buildRustPackage {
          pname = "codetracer-beam-recorder";
          version = cargoToml.package.version;

          src = ./.;
          cargoLock.lockFile = ./Cargo.lock;
          nativeBuildInputs = with pkgs; [
            capnproto
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
            shellHook = preCommit.shellHook + ''
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
