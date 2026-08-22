# CTFS Output and `ct print` Workflow

The recorder writes a CodeTracer Trace File System (CTFS) bundle to
the directory given via `--out-dir`. A CTFS bundle is a directory of
artifacts the CodeTracer reader can consume directly; it is not a
single tarball.

## Bundle layout

```text
<out-dir>/
├── *.ct                       # canonical CTFS file (binary)
├── trace_meta.json            # bundle metadata + runtime session info
├── runtime_session.jsonl      # per-event sidecar (JSON Lines)
├── recorder_metadata/
│   ├── manifests/
│   │   └── <Module>.manifest.json
│   └── low_level_events.ctfs  # low-level supplement (see below)
├── source_map/                # copied sources, project-relative paths
└── files/                     # legacy alias for source_map/ (links)
```

- `*.ct` is the binary CTFS file the reader consumes. `read-bundle-summary`
  loads it through `NimTraceReaderHandle` (the same reader the GUI uses).
- `trace_meta.json` records the source language (`elixir` / `erlang`),
  the runtime session mode (`beam`), the root pid, and the
  bundle-format version.
- `runtime_session.jsonl` is the recorder's append-only event log:
  one JSON object per line, with `event` set to one of `manifest_loaded`,
  `thread_start`, `thread_switch`, `thread_exit`, `call`, `return_from`,
  `exception_from`, `process_spawn`, `process_exit`, `message_send`,
  `message_receive`, `step`, `variable_bind`, `drop_variables`, or
  `trace_delivered`.
- `recorder_metadata/manifests/` holds one JSON manifest per recorded
  module ([schema](manifest-schema.md)).
- `source_map/` (and the legacy `files/` alias) is a copy of the
  recorded sources keyed by project-relative path.
- `recorder_metadata/low_level_events.ctfs` is a **separate** CTFS
  container holding the low-level supplement: `DropVariables` and the raw
  `Value` / `VariableName` records. They live outside the recording's own
  `.ct` on purpose — see below.

### Why the low-level supplement is a separate container

`NimTraceWriter::drop_variables` is a documented no-op: the Nim
multi-stream writer's C API cannot express `DropVariables`, so the
recorder encodes those records itself, in the legacy combined
`events.log` + `events.fmt` form.

Writing that `events.log` into the recording's own `.ct` made the
container a hybrid — a v4 multi-stream trace that also looks like a
legacy bundle. `ct print` diverts to its legacy combined-stream reader
for **any** container that carries an `events.log`, so it then decoded
the supplement instead of the trace, and failed outright on the
`HEADERV1` prefix the Rust CTFS writer and reader both use but the
legacy reader's chunk walk does not skip:

```text
Error reading events: chunk compressed data extends beyond events.log
```

Every instrumented BEAM recording — `erl`, `rebar3`, `elixir` and
`escript` — was therefore undecodable by the product's own decoder.
Keeping the supplement in its own container leaves the recording a clean
multi-stream bundle. Read it with
`codetracer_trace_reader::ctfs_reader::read_trace_from_ctfs` against
`recorder_metadata/low_level_events.ctfs`; the recorder's own tests do.

The underlying gap — a writer capability the Nim C API does not expose —
is upstream in `codetracer-trace-format` / `codetracer-trace-format-nim`,
as is the legacy reader's missing `HEADERV1` skip.

## `ct print` workflow

`ct print` is the canonical CTFS-to-text converter that ships with the
CodeTracer reader. The recorder is intentionally write-only — it does
not duplicate `ct print`'s functionality. To inspect a bundle:

```sh
ct print <bundle> --format text --limit 200
```

Common modes:

- `--format text` — human-readable rendering of the step stream.
- `--format json` — raw JSON event stream (one event per line).
- `--limit N` — truncate to the first N events (useful for stress
  bundles).
- `--filter call` — emit only `call` events.

`ct print` lives in the `codetracer` repo; if you do not have it
installed locally, run `nix run github:metacraft-labs/codetracer#ct-print`
or use `read-bundle-summary` for a quick sanity check.

## Verifying a recorded bundle

The recorder ships its own thin verifier — `read-bundle-summary` —
that loads the bundle through the same reader the GUI uses. It
emits a single JSON line and is ideal for integration tests:

```sh
codetracer-beam-recorder read-bundle-summary --bundle <out-dir>
```

The summary covers thread lifecycle counts, sidecar event counts, and
the `trace_delivered` finalize status. The four M17 verification tests
all assert against this exact projection.
