# Launch targets

`codetracer-beam-recorder record [OPTIONS] -- <command> [args]` wraps a
**launch command** rather than taking a script path, because a BEAM program is
normally started by its build tool. This document is the normative
specification of which launch commands the recorder understands, what each one
implies about the program's language, how `--source-dir` is used for each, and
what "M4 runtime injection" means for each.

It is the design document for the `elixir` and `escript` targets; the `mix`,
`erl` and `rebar3` targets are documented here too so the table is complete and
the differences are visible.

## 1. The target table

`is_beam_target()` in `src/main.rs` holds the closed list. A command outside it
is a **non-BEAM target**: the recorder runs it verbatim, records no BEAM events,
and says so in `trace_meta.json` (`"mode": "non_beam"`). A command inside it
**must** have a `prepare_*_target` implementation — `prepare_target()` fails
loudly otherwise, and never falls back to running it uninstrumented.

| Launch command | Language recorded | Where the program comes from | Instrumented by |
| --- | --- | --- | --- |
| `mix run -e EXPR` | Elixir | the enclosing Mix project | `mix compile.codetracer` |
| `rebar3 shell --eval EXPR` | Erlang | the enclosing rebar3 project | the `rebar3_codetracer` plugin |
| `erl -s Module Function` | Erlang | `--source-dir` / `--build-dir` | `codetracer_forms:instrument_file/4` |
| `elixir <program>.ex` | Elixir | `--source-dir` (the single file) | standalone Elixir build (§4) |
| `escript <program>.erl` | Erlang | `--source-dir` (the single file) | `codetracer_forms:instrument_file/4` |

### Why `elixir` and `escript` exist

The CodeTracer desktop core builds exactly these two commands for a
single-file recording. From
`codetracer/src/ct/trace/recorder_dispatch.nim`:

```nim
of LangElixir:            # .ex / .exs
  args: @["record", "--out-dir", traceFolder,
          "--source-dir", program.parentDir,
          "--", elixirExe, program]
of LangErlang:            # .erl / .hrl
  args: @["record", "--out-dir", traceFolder,
          "--source-dir", program.parentDir,
          "--", escriptExe, program]
```

That is the contract this recorder implements. It is not negotiable from this
side: `ct record foo.ex` reaches here as `-- elixir foo.ex`, and the recorder
either records it or fails — the one thing it must never do is exit 0 having
recorded nothing (§6).

### Language mapping

`detect_target_language()` records the source language in
`trace_meta.json`:

| Command | `language` | Why |
| --- | --- | --- |
| `mix`, `elixir` | `elixir` | Elixir toolchain |
| `erl`, `rebar3`, `escript` | `erlang` | Erlang toolchain. `escript` is Erlang-first because the core only reaches it for `.erl`/`.hrl` programs; an Elixir escript is out of scope (§5). |
| anything else | `elixir` | the legacy default, kept for M2/M3 fixture compatibility |

## 2. What `--source-dir` means per target

`--source-dir` names the directory the recorder should treat as the program's
own sources. Its meaning is deliberately **not** uniform, because a `.ex` file
under a source directory means different things in different projects:

- **`mix`** — Mix compiles the project and `mix compile.codetracer`
  instruments it. The recorder must not compile Elixir itself, or the program's
  modules would be built twice from two toolchains.
- **`rebar3`** — an Erlang project. A `.ex` file under `--source-dir` there is
  a *source-map original* (see
  `test-programs/erlang/rebar3_app/lib/original_generated.ex`), i.e. the
  original side of a generated-code mapping. It is never a compilation unit.
- **`erl` / `escript`** — `.erl` sources are compiled and instrumented by
  `codetracer_forms:instrument_file/4`.
- **`elixir`** — the single-file program *is* the compilation unit and nothing
  else will compile it. This is the only target for which the recorder compiles
  Elixir itself; see §4.

The standalone `compile` / `instrument` subcommands carry no launch target and
keep the `rebar3`-style behaviour: `.ex` files contribute trace functions
through source scanning, not through compilation.

`--source-dir` is also what makes the program's sources appear inside the
trace bundle (`<out-dir>/files/…`), which is the observable effect the
launcher↔recorder compatibility gate checks — see
`cross-repo/launcher-compat.yml`.

## 3. M4 runtime injection

Every BEAM target's prepared command must do three things before the program's
own code runs:

1. put the compiled CodeTracer runtime app (`codetracer_erlang_runtime`) on the
   code path;
2. put the instrumented ebin on the code path *ahead of* any uninstrumented
   copy of the same modules;
3. bracket the program's entry point with
   `codetracer_erlang_runtime:start_session/1` and `stop_session/1`.

### `elixir <program>.ex`

```
elixir -e ':code.add_patha(~c"<runtime ebin>"); :code.add_patha(~c"<instrumented ebin>");
           <purge program modules>;
           :ok = :codetracer_erlang_runtime.start_session([…]);
           try do Code.require_file("<generated entry script>")
           after :ok = :codetracer_erlang_runtime.stop_session(:normal) end'
```

The wrapper is `wrap_elixir_expression()` — the same one the `mix run -e` path
uses, so the two Elixir entry points share one injection implementation.

**The program file is not re-run as a script.** Running `elixir foo.ex` inside
the recording would recompile `foo.ex` in the target VM and *shadow* the
instrumented modules already on the code path, so the recording would again
capture nothing — differently, but just as silently. Instead the build split
the file ahead of time and this runs only the half that is the entry point
(§4).

### `escript <program>.erl`

```
erl -noshell -pa <runtime ebin> -pa <instrumented ebin>
    -eval 'codetracer_erlang_runtime:start_session([…]),
           try apply(<module>, main, [<script args>]) of _ ->
               codetracer_erlang_runtime:stop_session(normal), halt(0)
           catch Class:Reason:Stack ->
               codetracer_erlang_runtime:stop_session({Class,Reason}),
               erlang:raise(Class, Reason, Stack) end.'
```

**The launcher is switched from `escript` to `erl` on purpose.** `escript` runs
a bare `.erl` file by compiling it and calling `main/1`, and it offers no way to
add a directory to the code path: its emulator flags come from the script's own
`%%!` line, which the recorder must not rewrite. `erl` is the emulator `escript`
is a thin wrapper over, and it is the only way to get the instrumented ebin in
front of the source file's own compilation.

The entry-point contract — `Module:main(Args)` with `Args` the list of
argument strings — is reproduced faithfully. Several *surrounding* escript
semantics are **not**, because they belong to the `escript` wrapper rather
than to the emulator. They are enumerated in
[`known-limitations.md`](known-limitations.md#escript-target-semantics-not-reproduced):
`halt/1` exit codes, the uncaught-exception exit code, the script's own `%%!`
emulator flags, and the leading script path in
`init:get_plain_arguments/0`. Extra arguments after the program are passed
through both as `main/1`'s argument and as `erl -extra`, so
`init:get_plain_arguments/0` sees the arguments themselves — but not the
script path escript puts in front of them.

## 4. Instrumented compilation for a bare `.ex`

This is the hard part of the `elixir` target, and the reason accepting the
target in `is_beam_target()` alone is not a fix.

Elixir instrumentation normally lives in the Mix compiler task
`compile.codetracer`, which:

1. runs `mix compile` with `debug_info` on,
2. reads each produced `.beam`'s `debug_info` chunk back into **Erlang abstract
   forms**,
3. hands those forms to `codetracer_forms:instrument_abstract_forms/5` — the
   same instrumenter the Erlang path uses,
4. derives source maps, step locations, manifests and trace functions from the
   forms, and
5. writes a `codetracer.beam.standalone-build.v1` summary the Rust recorder
   reads.

Steps 2–5 need no Mix at all. Only step 1 does. So the standalone build
replaces step 1 and reuses steps 2–5 verbatim: `build_mix_project/1` and
`build_standalone/1` in `lib/codetracer_beam_recorder/elixir_source_map.ex`
now share one `finalize_build/5`, so a bare `elixir foo.ex` recording carries
exactly the same manifests, source maps and step locations as a Mix recording.

### The compile step: an AST split, not a file compile

A bare `.ex` script mixes two things a Mix project keeps apart:

- **module definitions**, which must be compiled ahead of time so their
  `debug_info` can be instrumented; and
- **top-level expressions**, which are the program's entry point and must run
  exactly once, inside a started recording session.

Whole-file compilation cannot separate them: compiling an Elixir file
*executes* its top-level code, so `elixirc foo.ex` would run the program —
uninstrumented, at build time, printing its output into the middle of the
build.

`compile_standalone_source!/3` therefore parses the file and splits its
top-level forms:

- `defmodule` / `defprotocol` / `defimpl` (plus any top-level `alias` /
  `import` / `require` directives they depend on) are compiled with
  `Code.compile_quoted(ast, path)` and the resulting BEAM binaries written out.
  Passing the original `path` keeps the real `.ex` file name and line numbers
  in the module's `debug_info`, which is what makes the reconstructed Erlang
  forms map back onto the user's source exactly as they do under Mix.
- everything else is written to a generated entry script under
  `<build-dir>/elixir_units/entry/`, whose path is reported back to the
  recorder in the build summary's `elixir_entries` and run by
  `prepare_elixir_target`.

The build driver is `scripts/standalone-elixir-build.exs`, run by the recorder
under the **same `elixir` binary it is about to hand the program to**. That is
deliberate: a dev shell can pin `elixir` and `erl` to different OTP releases
(this repo's pins Elixir 1.18 on OTP 27 and Erlang 28), and a BEAM file emitted
by a newer `erlc` cannot be loaded by an older emulator. `runtime_compiler_for_target()`
applies the same rule to the CodeTracer runtime app.

### Alternatives considered and rejected

- **Generate a throwaway Mix project around the file and run
  `mix compile.codetracer`.** Rejected: it needs `mix` on `PATH` (not among the
  runtimes the compatibility contract pins), it imposes Mix's app/module naming
  and `lib/` layout on a file that has neither, it writes `_build` and `deps`
  next to the user's program, and it would still have to solve the top-level
  expression problem — Mix would execute the script's top-level code during
  compilation just as `elixirc` does.
- **`elixirc <program>.ex -o ebin`.** Rejected for the reason above: it runs
  the program at build time. It also gives no way to recover the entry
  expression afterwards.
- **Reimplement the debug-info → forms → instrument pipeline in Rust or
  Erlang.** Rejected: it would fork the Elixir semantics (source maps, macro
  expansion events, function discovery) into a second implementation that would
  drift from `compile.codetracer`.
- **Run `elixir foo.ex` and instrument at load time.** Not possible: the
  instrumentation is an abstract-forms transform over an already-compiled
  module's `debug_info`, so it has to happen before the module is loaded.

### Known semantic deviations

Stated rather than papered over:

- **Module bodies run at build time, not at record time.** Compiling a module
  executes its body (module attributes, `use` macros). Under `elixir foo.ex`
  that happens during the run; here it happens during the build. This is the
  same deviation Mix has, and it is why the fixtures are required to be
  deterministic and side-effect-free at module level.
- `__DIR__` and `__ENV__.file` inside *top-level* code refer to the generated
  entry script, not the original file. Code inside modules is unaffected — it
  carries the original file through `debug_info`.
- Only the program's own modules are instrumented. Standard-library and
  dependency calls appear as effects, not as traced calls.

## 5. What these targets do not do

- `escript` with an **escript archive** or a shebang script (no `.erl`
  extension) is refused with a named diagnostic. There is no instrumentable
  source for the recorder to compile; the diagnostic points at
  `-- rebar3 shell --eval …` or `-- erl -s <module> <function>` instead.
- `.hrl` programs reach the recorder as `-- escript foo.hrl` (the desktop
  capability file routes `.hrl`). A header file defines no `main/1`, so this is
  refused by the same check. That is the honest answer; a header file is not a
  program.
- `elixir -e <expression>` (an option where the program is expected) is
  refused, with a pointer at `-- mix run -e <expression>`.

The `.ex` shapes the AST split cannot compile ahead of time are refused too,
each with a diagnostic that names the reason. All of them are cases where the
alternative would be an incomplete recording, so all of them exit non-zero:

- **A module defined inside a top-level expression** (`if … do defmodule … end
  end`, a `for` comprehension, a `case` arm). Only forms at the top level of
  the file can be compiled ahead of the recording; a module built inside a
  top-level expression would be compiled while the program runs, and recorded
  uninstrumented. This is refused *even when other modules did compile* —
  otherwise the recording would silently describe only part of the program,
  which is the exact failure this target exists to eliminate. `quote` blocks
  are exempt: a `defmodule` inside a quoted expression is a template, not a
  definition.
- **A script with no module definitions at all** (a pure top-level program).
  There is nothing to instrument, so there is nothing to record; the recorder
  says so rather than producing a trace of the program's lifecycle alone.
- **`defmodule` with a computed name** (`defmodule Module.concat([…]) do`).
  The name is only known once the enclosing expression runs, so the module
  cannot be compiled and instrumented ahead of the recording.

## 6. The guard against silent empty recordings

`codetracer-specs/CLI/ct/record.md` states the rule this recorder broke:

> The recorder produced no trace but exited 0. Treat as a failure. A missing
> trace with a success exit is the silent-incompleteness pattern.

A trace that exists but describes none of the program is the same failure
wearing a better disguise: the program still runs and still prints to the
terminal, so the recording *looks* successful. Four checks now make that
impossible for a BEAM target:

1. `prepare_target()` fails on a BEAM launch command it has no injection for,
   naming the command and the supported set. It never silently runs it
   uninstrumented.
2. `prepare_standalone_build()` fails if no source was compiled into an
   instrumented ebin, naming the source directories and how many Erlang and
   compilable-Elixir sources were found; and fails if the instrumented ebin
   yielded no traceable functions.
3. `RuntimeSession::prepare()` fails if a BEAM target produced no traceable
   functions at all, naming the target and the directory it searched, and
   pointing at `--source-dir`. `prepare_from_standalone_build()` applies the
   same check to a prebuilt `--build-dir`.
4. `prepare_elixir_target()` / `prepare_escript_target()` fail if the specific
   program named on the command line is not among the instrumented modules —
   the case where *something* was instrumented but not the thing being
   recorded.

All of these exit non-zero with a machine-readable
`{"type":"recorder_error","code":…,"message":…,"detail":…}` diagnostic.

Non-BEAM targets are unaffected: `record -- sh -c 'exit 7'` still runs the
command verbatim and still propagates exit 7.

## 7. Recorded output

The recorder pipes the target's stdout and stderr, forwards every byte to its
own streams as it arrives (so a recorded run looks and behaves exactly like an
unrecorded one), and writes a copy into the trace as `EventLogKind::Write`
events tagged `stdout` / `stderr`. `read-bundle-summary` surfaces them as
`recorded_output`.

**Forwarding is byte-exact; the recorded copy is normalised.** What reaches
the terminal is the child's bytes unmodified. What lands in the trace is one
event per *line*, decoded with `String::from_utf8_lossy` — so a trailing
`\r` is dropped from CRLF output, and any non-UTF-8 byte becomes U+FFFD. The
trace's event model is text lines, not a byte stream; do not read
`recorded_output` as a faithful transcript of binary output.

This is what makes "did the recording capture the run, or merely accompany it?"
answerable from the trace alone — the question the original defect could not be
asked, because a recorder that instrumented nothing still let the program print
to the terminal.

**Limitation, stated:** the output events are appended after the runtime's own
trace events rather than interleaved with them. The recorder observes the
child's pipes from outside the BEAM and shares no clock with the in-VM tracer,
so any claimed interleaving would be invented.

## 8. Related

- [`cli.md`](cli.md) — the full `record` option list.
- [`mix-integration.md`](mix-integration.md) — the `mix` target.
- [`rebar3-integration.md`](rebar3-integration.md) — the `rebar3` target.
- [`source-maps.md`](source-maps.md) — the source-map artifacts §4 produces.
- `cross-repo/launcher-compat.yml` — the checked-in launcher↔recorder
  contract these two targets exist to satisfy.
- `codetracer-specs/Recorder-CLI-Conventions.md` — the cross-recorder CLI
  conventions.
