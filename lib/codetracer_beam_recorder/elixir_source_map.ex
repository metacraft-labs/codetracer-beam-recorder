defmodule CodetracerBeamRecorder.CompilerTraceCollector do
  @moduledoc false

  use GenServer

  def start_link(path) do
    GenServer.start_link(__MODULE__, path, name: __MODULE__)
  end

  def record(event, env) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:record, event, env})
    end

    :ok
  end

  def stop do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.call(pid, :stop, :infinity)
    end
  end

  @impl true
  def init(path) do
    File.mkdir_p!(Path.dirname(path))
    {:ok, file} = File.open(path, [:write, :utf8])
    {:ok, %{file: file}}
  end

  @impl true
  def handle_cast({:record, event, env}, state) do
    IO.write(state.file, [JasonCompat.encode!(trace_record(event, env)), "\n"])
    {:noreply, state}
  end

  @impl true
  def handle_call(:stop, _from, state) do
    File.close(state.file)
    {:stop, :normal, :ok, state}
  end

  defp trace_record(event, env) do
    {event_name, event_payload} = normalize_event(event)

    %{
      schema: "codetracer.elixir.compiler-trace.v1",
      event: event_name,
      payload: event_payload,
      env: %{
        file: env.file,
        line: env.line,
        module: inspect_env_atom(env.module),
        function: inspect_env_function(env.function),
        context: inspect_env_atom(env.context),
        lexical_tracker: inspect(env.lexical_tracker)
      }
    }
  end

  defp normalize_event(:start), do: {"start", %{}}
  defp normalize_event(:stop), do: {"stop", %{}}

  defp normalize_event({:on_module, bytecode, _ignored}) do
    {"on_module", %{bytecode_size: byte_size(bytecode)}}
  end

  defp normalize_event({kind, meta, module, name, arity})
       when kind in [:remote_function, :remote_macro, :imported_function, :imported_macro] do
    {Atom.to_string(kind),
     %{
       line: Keyword.get(meta, :line),
       column: Keyword.get(meta, :column),
       module: inspect_env_atom(module),
       name: Atom.to_string(name),
       arity: arity,
       from_macro: Keyword.get(meta, :from_macro, false)
     }}
  end

  defp normalize_event({kind, meta, name, arity}) when kind in [:local_function, :local_macro] do
    {Atom.to_string(kind),
     %{
       line: Keyword.get(meta, :line),
       column: Keyword.get(meta, :column),
       name: Atom.to_string(name),
       arity: arity,
       from_macro: Keyword.get(meta, :from_macro, false)
     }}
  end

  defp normalize_event({kind, meta, module, opts}) when kind in [:import, :require] do
    {Atom.to_string(kind),
     %{
       line: Keyword.get(meta, :line),
       column: Keyword.get(meta, :column),
       module: inspect_env_atom(module),
       from_macro: Keyword.get(meta, :from_macro, false),
       opts: inspect(opts)
     }}
  end

  defp normalize_event({:alias, meta, alias, as, opts}) do
    {"alias",
     %{
       line: Keyword.get(meta, :line),
       column: Keyword.get(meta, :column),
       alias: inspect_env_atom(alias),
       as: inspect_env_atom(as),
       opts: inspect(opts)
     }}
  end

  defp normalize_event({:alias_expansion, meta, as, alias}) do
    {"alias_expansion",
     %{
       line: Keyword.get(meta, :line),
       column: Keyword.get(meta, :column),
       as: inspect_env_atom(as),
       alias: inspect_env_atom(alias)
     }}
  end

  defp normalize_event({:alias_reference, meta, module}) do
    {"alias_reference",
     %{
       line: Keyword.get(meta, :line),
       column: Keyword.get(meta, :column),
       module: inspect_env_atom(module)
     }}
  end

  defp normalize_event({:struct_expansion, meta, module, keys}) do
    {"struct_expansion",
     %{
       line: Keyword.get(meta, :line),
       column: Keyword.get(meta, :column),
       module: inspect_env_atom(module),
       keys: Enum.map(keys, &inspect/1)
     }}
  end

  defp normalize_event(other), do: {"other", %{term: inspect(other)}}

  defp inspect_env_atom(nil), do: nil
  defp inspect_env_atom(value) when is_atom(value), do: Atom.to_string(value)
  defp inspect_env_atom(value), do: inspect(value)

  defp inspect_env_function(nil), do: nil
  defp inspect_env_function({name, arity}), do: "#{name}/#{arity}"
end

defmodule CodetracerBeamRecorder.CompilerTracer do
  @moduledoc false

  def trace(event, env) do
    CodetracerBeamRecorder.CompilerTraceCollector.record(event, env)
  end
end

defmodule CodetracerBeamRecorder.ElixirSourceMap do
  @moduledoc false

  @runtime_modules ~w[
    codetracer_erlang_runtime.erl
    codetracer_session.erl
    codetracer_forms.erl
    codetracer_value_encoder.erl
  ]

  def recorder_root do
    System.get_env("CODETRACER_BEAM_RECORDER_ROOT") ||
      System.get_env("CODETRACER_ELIXIR_RECORDER_ROOT") ||
      Path.expand("../..", __DIR__)
  end

  def default_build_dir do
    Path.expand("_codetracer/beam-recorder/mix")
  end

  def build_mix_project(opts \\ []) do
    build_dir = Path.expand(Keyword.get(opts, :build_dir) || default_build_dir())
    include_apps = MapSet.new(Keyword.get(opts, :include_apps, []))
    exclude_apps = MapSet.new(Keyword.get(opts, :exclude_apps, []))
    include_modules = Keyword.get(opts, :include_modules, [])
    exclude_modules = Keyword.get(opts, :exclude_modules, [])
    source_root = File.cwd!()

    File.rm_rf!(build_dir)
    File.mkdir_p!(build_dir)

    ensure_task_ebin_on_code_path()
    runtime_ebin = compile_runtime_app!(build_dir)
    load_forms!(runtime_ebin)

    trace_file = Path.join(build_dir, "compiler_traces/events.jsonl")

    with_compiler_tracing(trace_file, fn ->
      Mix.Task.reenable("compile")
      Mix.Task.run("compile", ["--force"])
    end)

    app_infos = project_apps(source_root)
    selected_apps =
      app_infos
      |> Enum.reject(fn app -> MapSet.member?(exclude_apps, app.name) end)
      |> Enum.filter(fn app -> MapSet.size(include_apps) == 0 or MapSet.member?(include_apps, app.name) end)

    if selected_apps == [] do
      Mix.raise("codetracer app filters matched no Mix project apps")
    end

    compiler_events = read_compiler_events(trace_file)
    event_index = compiler_event_index(compiler_events)
    source_paths = collect_source_paths(selected_apps)
    module_filter = %{include: include_modules, exclude: exclude_modules}

    modules =
      selected_apps
      |> Enum.flat_map(&beam_modules_for_app/1)
      |> Enum.reject(fn module -> filtered_out_module?(module.module, module_filter) end)

    if modules == [] do
      Mix.raise("codetracer module filters matched no compiled Elixir modules")
    end

    summary = finalize_build(build_dir, source_root, modules, event_index, source_paths)

    File.write!(Path.join(build_dir, "standalone_build.json"), JasonCompat.encode_pretty!(summary))

    %{
      build_dir: build_dir,
      compiler_trace_file: trace_file,
      summary: summary
    }
  end

  @doc false
  # Shared tail of every Elixir build: take already-compiled BEAM modules,
  # reconstruct their Erlang abstract forms from `debug_info`, run them
  # through the same `codetracer_forms` instrumenter the Erlang path uses,
  # and write the recorder metadata (`standalone_build.json` shape,
  # schema `codetracer.beam.standalone-build.v1`).
  #
  # `build_mix_project/1` reaches here after `mix compile`; `build_standalone/1`
  # reaches here after compiling loose `.ex`/`.exs` files with the Elixir
  # compiler directly.  Everything downstream of the compiler is identical,
  # which is what makes a bare `elixir foo.ex` recording carry exactly the
  # same manifests, source maps and step locations as a Mix recording.
  def finalize_build(build_dir, source_root, modules, event_index, source_paths) do
    instrumented_ebin = Path.join(build_dir, "instrumented/ebin")
    locations_root = Path.join(build_dir, "recorder_metadata/step_locations")
    dumps_root = Path.join(build_dir, "recorder_metadata/transformed_forms")
    File.mkdir_p!(instrumented_ebin)
    File.mkdir_p!(locations_root)
    File.mkdir_p!(dumps_root)

    instrumented =
      Enum.flat_map(modules, fn module ->
        case debug_info_forms(module.beam_path) do
          {:ok, forms} ->
            source_path = module_source_path(forms, module)
            generated_path = generated_source_path(build_dir, module.module)
            File.mkdir_p!(Path.dirname(generated_path))
            File.write!(generated_path, pretty_forms(forms))

            safe = safe_filename(module.module)
            locations_path = Path.join(locations_root, "#{safe}.step-locations.json")
            dump_path = Path.join(dumps_root, "#{safe}.transformed.erl")

            case apply(:codetracer_forms, :instrument_abstract_forms, [
                   forms,
                   String.to_charlist(generated_path),
                   String.to_charlist(instrumented_ebin),
                   String.to_charlist(locations_path),
                   String.to_charlist(dump_path)
                 ]) do
              :ok ->
                [
                  %{
                    module: module.module,
                    source_path: source_path,
                    generated_path: generated_path,
                    locations_path: locations_path,
                    dump_path: dump_path,
                    forms: forms
                  }
                ]

              {:error, reason} ->
                Mix.raise("codetracer failed to instrument #{module.module}: #{inspect(reason)}")
            end

          {:error, reason} ->
            notify("codetracer skipping #{module.module}: #{inspect(reason)}")
            []
        end
      end)

    source_maps = source_maps_for_modules(source_root, instrumented, event_index)
    step_locations = read_step_locations(source_root, source_maps, instrumented)
    trace_functions = trace_functions_for_modules(source_root, source_maps, instrumented)
    variable_slots = read_variable_slot_templates(instrumented)
    transformed_dumps = transformed_dumps(instrumented)
    {source_map_artifacts, manifest_artifacts} =
      write_metadata(build_dir, source_root, source_maps, trace_functions, step_locations, variable_slots, transformed_dumps)

    %{
      schema: "codetracer.beam.standalone-build.v1",
      build_dir: build_dir,
      source_root: source_root,
      source_paths: source_paths,
      instrumented_ebin: instrumented_ebin,
      manifests: manifest_artifacts,
      source_maps: source_map_artifacts,
      transformed_form_dumps: transformed_dumps,
      trace_functions: trace_functions,
      step_locations: step_locations
    }
  end

  # --------------------------------------------------------------------
  # Standalone (no Mix project) Elixir build — the `elixir <program>.ex`
  # launch target.
  #
  # See docs/launch-targets.md §"elixir".  The short version: a bare
  # `.ex` script mixes two things that a Mix project keeps apart —
  # MODULE DEFINITIONS (which must be compiled ahead of time so
  # `codetracer_forms` can instrument their abstract forms) and TOP-LEVEL
  # EXPRESSIONS (which are the program's entry point and must run only
  # once, under a started recording session).  `elixirc`-style whole-file
  # compilation cannot separate them: compiling a file EXECUTES its
  # top-level code, so the program would run — uninstrumented — during
  # the build.
  #
  # So the split is done on the parsed AST, and each half is given to the
  # tool that wants it:
  #
  #   * `defmodule` / `defprotocol` / `defimpl` forms (plus any top-level
  #     `alias` / `import` / `require` directives they depend on) are
  #     compiled with `Code.compile_quoted/2` and the resulting BEAM
  #     binaries written out.  `Code.compile_quoted(ast, file)` keeps the
  #     ORIGINAL `.ex` path and line numbers in the module's `debug_info`,
  #     which is what makes the reconstructed Erlang forms map back onto
  #     the user's `.ex` file exactly as they do under Mix.
  #   * everything else is written to a generated entry script whose path
  #     is reported back to the recorder, which runs it inside the
  #     `start_session` / `stop_session` wrapper.
  # --------------------------------------------------------------------

  @standalone_entry_schema "codetracer.beam.standalone-elixir-entry.v1"

  def build_standalone_from_spec!(spec_path) do
    spec = spec_path |> File.read!() |> JasonCompat.decode!()

    build_standalone(
      build_dir: Map.fetch!(spec, "build_dir"),
      source_root: Map.fetch!(spec, "source_root"),
      sources: Map.fetch!(spec, "sources"),
      runtime_ebin: Map.fetch!(spec, "runtime_ebin"),
      summary_path: Map.fetch!(spec, "summary_path"),
      include_modules: Map.get(spec, "include_modules") || [],
      exclude_modules: Map.get(spec, "exclude_modules") || []
    )
  end

  def build_standalone(opts) do
    build_dir = opts |> Keyword.fetch!(:build_dir) |> Path.expand()
    source_root = opts |> Keyword.fetch!(:source_root) |> Path.expand()
    sources = opts |> Keyword.fetch!(:sources) |> Enum.map(&Path.expand/1)
    runtime_ebin = opts |> Keyword.fetch!(:runtime_ebin) |> Path.expand()
    summary_path = opts |> Keyword.fetch!(:summary_path) |> Path.expand()
    include_modules = Keyword.get(opts, :include_modules, [])
    exclude_modules = Keyword.get(opts, :exclude_modules, [])

    if sources == [] do
      Mix.raise("codetracer standalone Elixir build was given no .ex/.exs sources")
    end

    File.mkdir_p!(build_dir)
    load_forms!(runtime_ebin)

    unit_ebin = Path.join(build_dir, "elixir_units/ebin")
    entry_root = Path.join(build_dir, "elixir_units/entry")
    File.rm_rf!(unit_ebin)
    File.mkdir_p!(unit_ebin)
    File.mkdir_p!(entry_root)

    trace_file = Path.join(build_dir, "compiler_traces/elixir_standalone_events.jsonl")

    units =
      with_compiler_tracing(trace_file, fn ->
        Enum.map(sources, &compile_standalone_source!(&1, unit_ebin, entry_root))
      end)

    module_filter = %{include: include_modules, exclude: exclude_modules}

    modules =
      units
      |> Enum.flat_map(fn unit ->
        Enum.map(unit.modules, fn module ->
          %{
            app: "standalone",
            app_root: source_root,
            module: module.module,
            beam_path: module.beam_path
          }
        end)
      end)
      |> Enum.reject(fn module -> filtered_out_module?(module.module, module_filter) end)

    if modules == [] do
      Mix.raise(
        "codetracer standalone Elixir build produced no instrumentable modules from " <>
          "#{Enum.join(sources, ", ")} (module filters: include=#{inspect(include_modules)} " <>
          "exclude=#{inspect(exclude_modules)})"
      )
    end

    event_index = trace_file |> read_compiler_events() |> compiler_event_index()

    summary =
      build_dir
      |> finalize_build(source_root, modules, event_index, sources)
      |> Map.put(:elixir_entries, Enum.map(units, &entry_record/1))

    File.write!(summary_path, JasonCompat.encode_pretty!(summary))
    summary
  end

  defp entry_record(unit) do
    %{
      schema: @standalone_entry_schema,
      source_path: unit.source_path,
      entry_path: unit.entry_path,
      expression: unit.expression,
      modules: Enum.map(unit.modules, & &1.module)
    }
  end

  defp compile_standalone_source!(path, unit_ebin, entry_root) do
    quoted =
      path
      |> File.read!()
      |> Code.string_to_quoted!(file: path, columns: true)

    forms =
      case quoted do
        {:__block__, _meta, list} when is_list(list) -> list
        other -> [other]
      end

    {module_forms, entry_forms} = Enum.split_with(forms, &module_definition_form?/1)

    # A `defmodule` nested inside a TOP-LEVEL EXPRESSION (`if`, `case`, `for`,
    # `with`, ...) is not a top-level module form, so the split above leaves it
    # in the entry script -- where it would be compiled at RECORD time, on the
    # code path, UNINSTRUMENTED, while the recording still exited 0.  If the
    # file also defines a module at the top level, nothing else notices: the
    # build succeeds, the guards in docs/launch-targets.md §6 all pass (they
    # only fire when NOTHING was instrumented), and the user gets a trace that
    # silently describes half their program.  That is precisely the
    # silent-incompleteness pattern codetracer-specs/CLI/ct/record.md forbids
    # and this launch target exists to eliminate, so refuse it by name.
    case nested_module_definitions(entry_forms) do
      [] ->
        :ok

      nested ->
        Mix.raise(
          "codetracer cannot instrument #{path}: it defines #{Enum.join(nested, ", ")} inside a " <>
            "top-level expression. The `elixir <program>.ex` target compiles module definitions " <>
            "ahead of the recording so their abstract forms can be instrumented, and only forms " <>
            "at the TOP LEVEL of the file can be compiled that way; a module defined inside " <>
            "`if`/`case`/`for` would be built while the program runs and recorded " <>
            "UNINSTRUMENTED. Move the module to the top level of the file, or record the " <>
            "enclosing project with `-- mix run -e <expression>`."
        )
    end

    directive_forms = Enum.filter(entry_forms, &directive_form?/1)

    compiled =
      case directive_forms ++ module_forms do
        [] -> []
        to_compile -> Code.compile_quoted({:__block__, [], to_compile}, path)
      end

    modules =
      Enum.map(compiled, fn {module, binary} ->
        beam_path = Path.join(unit_ebin, "#{module}.beam")
        File.write!(beam_path, binary)
        %{module: Atom.to_string(module), beam_path: beam_path}
      end)

    expression = entry_forms |> Enum.map(&Macro.to_string/1) |> Enum.join("\n")
    entry_path = Path.join(entry_root, "#{safe_filename(Path.basename(path))}.entry.exs")

    File.write!(entry_path, [
      "# codetracer generated entry script for ",
      path,
      "\n# Top-level expressions of the recorded `.ex` program, with its module\n",
      "# definitions removed (they are compiled and instrumented ahead of time).\n",
      expression,
      "\n"
    ])

    %{
      source_path: path,
      entry_path: entry_path,
      expression: expression,
      modules: modules
    }
  end

  # Module definitions reachable from `forms` but not AT the top level of the
  # file -- the ones `Enum.split_with(&module_definition_form?/1)` cannot see.
  #
  # `quote` blocks are pruned: a `defmodule` inside a quoted expression is a
  # TEMPLATE for a module, not a definition, and refusing those would reject
  # valid metaprogramming that the split already handles correctly.
  defp nested_module_definitions(forms) do
    forms
    |> Macro.prewalk([], fn
      {:quote, _, _}, acc ->
        {{:__block__, [], []}, acc}

      {definer, _, [name | _]} = node, acc
      when definer in [:defmodule, :defprotocol, :defimpl] ->
        {node, ["#{definer} #{Macro.to_string(name)}" | acc]}

      node, acc ->
        {node, acc}
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp module_definition_form?({:defmodule, _, _}), do: true
  defp module_definition_form?({:defprotocol, _, _}), do: true
  defp module_definition_form?({:defimpl, _, _}), do: true
  defp module_definition_form?(_), do: false

  defp directive_form?({directive, _, _}) when directive in [:alias, :import, :require], do: true
  defp directive_form?(_), do: false

  defp load_forms!(runtime_ebin) do
    Code.prepend_path(runtime_ebin)
    :code.add_patha(String.to_charlist(runtime_ebin))

    unless function_exported?(:codetracer_forms, :instrument_abstract_forms, 5) do
      case :code.load_file(:codetracer_forms) do
        {:module, :codetracer_forms} ->
          :ok

        {:error, reason} ->
          Mix.raise("failed to load codetracer_forms from #{runtime_ebin}: #{inspect(reason)}")
      end
    end

    :ok
  end

  defp with_compiler_tracing(trace_file, fun) do
    {:ok, _pid} = CodetracerBeamRecorder.CompilerTraceCollector.start_link(trace_file)
    old_tracers = Code.get_compiler_option(:tracers)
    old_debug_info = Code.get_compiler_option(:debug_info)
    Code.put_compiler_option(:debug_info, true)
    Code.put_compiler_option(:tracers, [CodetracerBeamRecorder.CompilerTracer | old_tracers])

    try do
      fun.()
    after
      Code.put_compiler_option(:tracers, old_tracers)
      Code.put_compiler_option(:debug_info, old_debug_info)
      CodetracerBeamRecorder.CompilerTraceCollector.stop()
    end
  end

  # `Mix.shell()` needs the `:mix` application's state process, which a bare
  # `elixir` run (the standalone build) does not have.  `Mix.raise/1` is a
  # plain function and works either way, so only the informational path
  # needs the fallback.
  defp notify(message) do
    Mix.shell().info(message)
  rescue
    _ -> IO.puts(message)
  catch
    _, _ -> IO.puts(message)
  end

  defp compile_runtime_app!(build_dir) do
    src_dir = Path.join(recorder_root(), "apps/codetracer_erlang_runtime/src")
    ebin_dir = Path.join(build_dir, "runtime/codetracer_erlang_runtime/ebin")
    File.mkdir_p!(ebin_dir)

    Enum.each(@runtime_modules, fn filename ->
      source = Path.join(src_dir, filename)
      {output, status} = System.cmd("erlc", ["+debug_info", "-o", ebin_dir, source], stderr_to_stdout: true)

      if status != 0 do
        Mix.raise("codetracer runtime compile failed for #{source}: #{output}")
      end
    end)

    File.cp!(
      Path.join(src_dir, "codetracer_erlang_runtime.app.src"),
      Path.join(ebin_dir, "codetracer_erlang_runtime.app")
    )

    Enum.each([:codetracer_forms, :codetracer_erlang_runtime, :codetracer_session, :codetracer_value_encoder], fn module ->
      :code.purge(module)
      :code.delete(module)
    end)

    ebin_dir
  end

  defp ensure_task_ebin_on_code_path do
    case :code.which(__MODULE__) do
      beam when is_list(beam) ->
        beam
        |> List.to_string()
        |> Path.dirname()
        |> Path.expand()
        |> Code.prepend_path()

      _ ->
        :ok
    end

    Code.ensure_loaded!(CodetracerBeamRecorder.CompilerTracer)
    Code.ensure_loaded!(JasonCompat)
    :ok
  end

  defp project_apps(source_root) do
    if File.dir?(Path.join(source_root, "apps")) do
      Path.wildcard(Path.join(source_root, "apps/*/mix.exs"))
      |> Enum.map(fn mix_file ->
        app_root = Path.dirname(mix_file)
        name = app_name_from_mix_file!(mix_file)
        %{name: name, root: app_root, ebin: app_ebin(name)}
      end)
    else
      name = Mix.Project.config() |> Keyword.fetch!(:app) |> Atom.to_string()
      [%{name: name, root: source_root, ebin: app_ebin(name)}]
    end
  end

  defp app_name_from_mix_file!(mix_file) do
    mix_file
    |> File.read!()
    |> then(fn text ->
      case Regex.run(~r/app:\s*:([a-zA-Z0-9_]+)/, text) do
        [_, app] -> app
        _ -> Mix.raise("cannot determine umbrella app name from #{mix_file}")
      end
    end)
  end

  defp app_ebin(app_name) do
    Path.join([Mix.Project.build_path(), "lib", app_name, "ebin"])
  end

  defp beam_modules_for_app(app) do
    app.ebin
    |> Path.join("*.beam")
    |> Path.wildcard()
    |> Enum.reject(&String.ends_with?(&1, ".app.beam"))
      |> Enum.map(fn path ->
        module =
          path
          |> Path.basename(".beam")
          |> String.to_atom()
          |> Atom.to_string()

      %{app: app.name, app_root: app.root, module: module, beam_path: path}
    end)
  end

  defp debug_info_forms(beam_path) do
    with {:ok, {module, [debug_info: {:debug_info_v1, backend, data}]}} <-
           :beam_lib.chunks(String.to_charlist(beam_path), [:debug_info]),
         {:ok, forms} <- backend.debug_info(:erlang_v1, module, data, []) do
      {:ok, forms}
    else
      {:ok, {_module, [debug_info: :no_debug_info]}} -> {:error, :no_debug_info}
      {:error, module, reason} -> {:error, {module, reason}}
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  defp module_source_path(forms, module) do
    forms
    |> Enum.find_value(fn
      {:attribute, _, :file, {file, _line}} -> List.to_string(file)
      _ -> nil
    end)
    |> case do
      nil -> module.beam_path
      path -> Path.expand(path, module.app_root)
    end
  end

  defp generated_source_path(build_dir, module) do
    Path.join([build_dir, "generated_erlang", "#{safe_filename(module)}.erl"])
  end

  defp pretty_forms(forms) do
    [
      "%% codetracer generated Erlang forms reconstructed from Elixir BEAM debug_info\n",
      Enum.map(forms, fn form -> :erl_pp.form(form) |> IO.iodata_to_binary() end)
    ]
  end

  defp read_compiler_events(path) do
    if File.regular?(path) do
      path
      |> File.stream!()
      |> Enum.map(&JasonCompat.decode!/1)
    else
      []
    end
  end

  defp compiler_event_index(events) do
    Enum.group_by(events, fn event ->
      get_in(event, ["env", "file"])
    end)
  end

  defp source_maps_for_modules(_source_root, modules, event_index) do
    Enum.map(modules, fn module ->
      mappings =
        module.forms
        |> Enum.flat_map(&form_locations/1)
        |> Enum.uniq()
        |> Enum.filter(fn {line, _column, generated} -> is_integer(line) and line > 0 and not generated end)
        |> Enum.map(fn {line, column, _generated} ->
          column = normalize_optional_u32(column)

          %{
            generated_line: line,
            generated_column: column,
            original_line: line,
            original_column: column,
            reason: "debug_info_erlang_v1"
          }
        end)

      %{
        schema: "codetracer.beam.sourcemap.v1",
        source_language: "elixir",
        generated_path: module.generated_path,
        original_path: module.source_path,
        macro_expansion_chain_policy:
          "v1 records compiler-tracer macro event summaries but not full nested expansion chains",
        macro_expansion_events: macro_events_for_file(event_index, module.source_path),
        mappings: mappings
      }
    end)
    |> Enum.reject(fn map -> map.mappings == [] end)
    |> Enum.sort_by(fn map -> {map.generated_path, map.original_path} end)
  end

  defp macro_events_for_file(event_index, source_path) do
    event_index
    |> Map.get(Path.expand(source_path), [])
    |> Enum.filter(fn event ->
      event["event"] in ["remote_macro", "local_macro", "imported_macro", "require"] or
        get_in(event, ["payload", "from_macro"]) == true
    end)
    |> Enum.map(fn event ->
      %{
        event: event["event"],
        line: get_in(event, ["payload", "line"]) || get_in(event, ["env", "line"]),
        module: get_in(event, ["payload", "module"]),
        name: get_in(event, ["payload", "name"]),
        arity: get_in(event, ["payload", "arity"])
      }
    end)
  end

  defp form_locations(term) when is_tuple(term) do
    locations =
      case Tuple.to_list(term) do
        [_tag, anno | _] -> List.wrap(anno_location(anno))
        _ -> []
      end

    locations ++ (term |> Tuple.to_list() |> Enum.flat_map(&form_locations/1))
  end

  defp form_locations(term) when is_list(term), do: Enum.flat_map(term, &form_locations/1)
  defp form_locations(_), do: []

  defp anno_location(anno) do
    line = safe_erl_anno(:line, anno)
    column = safe_erl_anno(:column, anno)
    generated = safe_erl_anno(:generated, anno) == true

    if is_integer(line) and line > 0 do
      {line, column, generated}
    else
      nil
    end
  end

  defp safe_erl_anno(function, anno) do
    case apply(:erl_anno, function, [anno]) do
      :undefined -> nil
      value -> value
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp read_step_locations(source_root, source_maps, modules) do
    modules
    |> Enum.flat_map(fn module ->
      parsed = module.locations_path |> File.read!() |> JasonCompat.decode!()

      recorded =
        parsed["locations"]
        |> Enum.map(fn raw ->
          resolved =
            resolve_source_location(
              source_root,
              source_maps,
              raw["source_path"],
              raw["line"],
              raw["column"]
            )

          %{
            module: parsed["module"],
            source_path: raw["source_path"],
            location_id: raw["id"],
            resolved_source_path: resolved.build_path,
            resolved_line: resolved.line,
            resolved_column: resolved.column,
            resolution_strategy: resolved.resolution,
            trace_copy_path: resolved.trace_copy_path,
            generated: raw["generated"]
          }
        end)

      recorded ++ generated_fallback_locations(module)
    end)
    |> Enum.uniq_by(& &1.location_id)
  end

  defp generated_fallback_locations(module) do
    module.forms
    |> Enum.flat_map(&form_locations/1)
    |> Enum.uniq()
    |> Enum.filter(fn {line, _column, generated} -> is_integer(line) and line > 0 and generated end)
    |> Enum.map(fn {line, column, _generated} ->
      column = normalize_optional_u32(column)

      %{
        module: module.module,
        source_path: module.generated_path,
        location_id: stable_id("#{module.module}:generated-fallback:#{line}:#{inspect(column)}"),
        resolved_source_path: module.generated_path,
        resolved_line: line,
        resolved_column: column,
        resolution_strategy: "unknown_generated_fallback",
        trace_copy_path: "generated/<unknown>",
        generated: true
      }
    end)
  end

  defp read_variable_slot_templates(modules) do
    modules
    |> Enum.flat_map(fn module ->
      module.locations_path
      |> File.read!()
      |> JasonCompat.decode!()
      |> Map.get("variable_slot_templates", [])
      |> Enum.map(fn slot ->
        %{
          function_key: slot["function_key"],
          slot: slot["slot"],
          name: slot["name"],
          source: slot["source"]
        }
      end)
    end)
    |> Enum.uniq_by(fn slot -> {slot.function_key, slot.slot} end)
  end

  defp trace_functions_for_modules(source_root, source_maps, modules) do
    modules
    |> Enum.flat_map(fn module ->
      module.forms
      |> Enum.flat_map(fn
        {:function, anno, name, arity, _clauses} ->
          line = safe_erl_anno(:line, anno) || 1
          column = safe_erl_anno(:column, anno)
          function = Atom.to_string(name)
          function_key = "#{module.module}.#{function}/#{arity}"
          resolved = resolve_source_location(source_root, source_maps, module.generated_path, line, column)

          [
            %{
              module: module.module,
              function: function,
              arity: arity,
              kind: "elixir",
              source_path: module.generated_path,
              line: line,
              manifest_id: "beam-manifest-v1:#{module.module}",
              function_key: function_key,
              location_id: stable_id("#{function_key}:location:#{line}"),
              clause_id: stable_id("#{function_key}:clause:#{line}"),
              resolved_source_path: resolved.build_path,
              resolved_line: resolved.line,
              resolved_column: resolved.column,
              resolution_strategy: resolved.resolution,
              trace_copy_path: resolved.trace_copy_path
            }
          ]

        _ ->
          []
      end)
    end)
    |> Enum.reject(fn function -> String.starts_with?(function.function, "-") end)
    |> Enum.reject(fn function -> function.function == "__info__" or function.line <= 0 end)
    |> Enum.uniq_by(fn function -> {function.module, function.function, function.arity, function.line} end)
  end

  defp transformed_dumps(modules) do
    Enum.map(modules, fn module ->
      %{
        module: module.module,
        format: "erl_pp:form/1 pretty-printed Erlang source",
        build_path: module.dump_path,
        trace_copy_path:
          "recorder_metadata/transformed_forms/#{Path.basename(module.dump_path)}",
        runtime_path: module.dump_path
      }
    end)
  end

  defp write_metadata(build_dir, source_root, source_maps, trace_functions, step_locations, variable_slots, dumps) do
    metadata_root = Path.join(build_dir, "recorder_metadata")
    source_maps_root = Path.join(metadata_root, "source_maps")
    manifests_root = Path.join(metadata_root, "manifests")
    File.mkdir_p!(source_maps_root)
    File.mkdir_p!(manifests_root)

    source_map_artifacts =
      source_maps
      |> Enum.with_index(1)
      |> Enum.map(fn {source_map, index} ->
        filename =
          "#{String.pad_leading(Integer.to_string(index), 3, "0")}-#{safe_filename(project_relative_path(source_root, source_map.generated_path))}.json"

        destination = Path.join(source_maps_root, filename)
        File.write!(destination, JasonCompat.encode_pretty!(source_map))

        %{
          source_language: source_map.source_language,
          generated_build_path: source_map.generated_path,
          original_build_path: source_map.original_path,
          trace_copy_path: "recorder_metadata/source_maps/#{filename}"
        }
      end)

    manifest_artifacts =
      trace_functions
      |> Enum.group_by(& &1.module)
      |> Enum.map(fn {module, functions} ->
        first = hd(functions)
        locations =
          (Enum.map(functions, &location_from_function(source_root, &1)) ++
             (step_locations
              |> Enum.filter(&(&1.module == module))
              |> Enum.map(&location_from_step(source_root, &1))))
          |> Enum.uniq_by(& &1.id)

        function_keys = MapSet.new(Enum.map(functions, & &1.function_key))
        slots =
          functions
          |> Enum.flat_map(fn function ->
            if function.arity == 0 do
              []
            else
              Enum.map(0..(function.arity - 1), fn slot ->
                %{
                  function_key: function.function_key,
                  slot: slot,
                  name: "_arg#{slot}",
                  source: "runtime_call_arg"
                }
              end)
            end
          end)
          |> Kernel.++(Enum.filter(variable_slots, &MapSet.member?(function_keys, &1.function_key)))
          |> Enum.uniq_by(fn slot -> {slot.function_key, slot.slot} end)

        referenced_maps =
          source_map_artifacts
          |> Enum.filter(fn source_map ->
            Enum.any?(functions, &(&1.source_path == source_map.generated_build_path)) or
              Enum.any?(step_locations, &(&1.source_path == source_map.generated_build_path))
          end)
          |> Enum.map(& &1.trace_copy_path)

        manifest = %{
          schema: "codetracer.beam.module-manifest.v1",
          encoding: "json",
          manifest_id: "beam-manifest-v1:#{module}",
          module: %{
            name: module,
            source_language: "elixir",
            build_path: first.source_path,
            project_relative_path: project_relative_path(source_root, first.resolved_source_path),
            trace_copy_path: first.trace_copy_path
          },
          functions:
            Enum.map(functions, fn function ->
              %{
                key: function.function_key,
                name: function.function,
                arity: function.arity,
                visibility: "unknown",
                location_id: function.location_id,
                clause_ids: [function.clause_id],
                traceable: true
              }
            end),
          locations: locations,
          clauses:
            Enum.map(functions, fn function ->
              %{
                id: function.clause_id,
                function_key: function.function_key,
                location_id: function.location_id
              }
            end),
          variable_slot_templates: slots,
          traceable_mfas:
            Enum.map(functions, fn function ->
              %{module: function.module, function: function.function, arity: function.arity}
            end),
          source_maps: referenced_maps
        }

        filename = "#{safe_filename(module)}.manifest.json"
        destination = Path.join(manifests_root, filename)
        File.write!(destination, JasonCompat.encode_pretty!(manifest))

        %{
          module: module,
          manifest_id: "beam-manifest-v1:#{module}",
          encoding: "json",
          schema: "codetracer.beam.module-manifest.v1",
          build_path: first.source_path,
          trace_copy_path: "recorder_metadata/manifests/#{filename}",
          runtime_path: destination
        }
      end)

    Enum.each(dumps, fn dump ->
      unless File.regular?(dump.runtime_path), do: Mix.raise("missing transformed dump #{dump.runtime_path}")
    end)

    {source_map_artifacts, manifest_artifacts}
  end

  defp location_from_function(source_root, function) do
    %{
      id: function.location_id,
      build_path: function.resolved_source_path,
      project_relative_path: project_relative_path(source_root, function.resolved_source_path),
      trace_copy_path: function.trace_copy_path,
      line: function.resolved_line,
      column: function.resolved_column,
      resolution: function.resolution_strategy
    }
  end

  defp location_from_step(source_root, step) do
    %{
      id: step.location_id,
      build_path: step.resolved_source_path,
      project_relative_path: project_relative_path(source_root, step.resolved_source_path),
      trace_copy_path: step.trace_copy_path,
      line: step.resolved_line,
      column: step.resolved_column,
      resolution: step.resolution_strategy
    }
  end

  defp resolve_source_location(source_root, source_maps, generated_path, line, column) do
    generated_path = Path.expand(generated_path)

    case find_source_map_entry(source_maps, generated_path, line, column) do
      {source_map, entry} ->
        original_path = Path.expand(source_map.original_path)

        %{
          build_path: original_path,
          trace_copy_path: trace_copy_path(source_root, original_path),
          line: entry.original_line,
          column: normalize_optional_u32(entry.original_column),
          resolution: "source_map"
        }

      nil ->
        %{
          build_path: generated_path,
          trace_copy_path: "generated/<unknown>",
          line: line || 1,
          column: normalize_optional_u32(column),
          resolution: "unknown_generated_fallback"
        }
    end
  end

  defp find_source_map_entry(source_maps, generated_path, line, column) do
    Enum.find_value(source_maps, fn source_map ->
      if Path.expand(source_map.generated_path) == generated_path do
        entry =
          Enum.find(source_map.mappings, fn entry ->
            entry.generated_line == line and
              (is_nil(entry.generated_column) or entry.generated_column == column)
          end)

        if entry, do: {source_map, entry}
      end
    end)
  end

  defp collect_source_paths(apps) do
    apps
    |> Enum.flat_map(fn app ->
      ["mix.exs", "lib/**/*.{ex,exs}", "test/**/*.{ex,exs}"]
      |> Enum.flat_map(&Path.wildcard(Path.join(app.root, &1)))
    end)
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp filtered_out_module?(_module, %{include: [], exclude: []}), do: false

  defp filtered_out_module?(module, %{include: include, exclude: exclude}) do
    included = include == [] or Enum.any?(include, &wildcard_match?(&1, module))
    excluded = Enum.any?(exclude, &wildcard_match?(&1, module))
    not included or excluded
  end

  defp wildcard_match?(pattern, value) do
    pattern =
      pattern
      |> Regex.escape()
      |> String.replace("\\*", ".*")
      |> then(&("^" <> &1 <> "$"))
      |> Regex.compile!()

    Regex.match?(pattern, value)
  end

  defp project_relative_path(source_root, path) do
    path = Path.expand(path)

    case Path.relative_to(path, source_root) do
      ^path -> path
      relative -> relative
    end
  end

  defp trace_copy_path(source_root, path) do
    "files/" <> String.replace(project_relative_path(source_root, path), "\\", "/")
  end

  defp safe_filename(value) do
    value
    |> String.replace(~r/[^A-Za-z0-9_.-]/, "_")
  end

  defp normalize_optional_u32(value) when is_integer(value), do: value
  defp normalize_optional_u32(_value), do: nil

  defp stable_id(text) do
    hash =
      text
      |> String.to_charlist()
      |> Enum.reduce(2_166_136_261, fn byte, acc ->
        Bitwise.band(Bitwise.bxor(acc, byte) * 16_777_619, 0xFFFFFFFF)
      end)

    if hash == 0, do: 1, else: hash
  end
end

defmodule JasonCompat do
  @moduledoc false

  def encode!(term), do: encode_value(term)
  def encode_pretty!(term), do: encode_value(term)

  def decode!(iodata) do
    binary = IO.iodata_to_binary(iodata)

    case Code.ensure_loaded(Jason) do
      {:module, Jason} ->
        apply(Jason, :decode!, [binary])

      _ ->
        normalize_json_nulls(:json.decode(binary))
    end
  end

  defp encode_value(term) do
    case Code.ensure_loaded(Jason) do
      {:module, Jason} -> apply(Jason, :encode!, [term])
      _ -> IO.iodata_to_binary(:json.encode(string_key_maps(term)))
    end
  end

  defp string_key_maps(map) when is_map(map) do
    map
    |> Enum.map(fn {key, value} -> {key_to_string(key), string_key_maps(value)} end)
    |> Map.new()
  end

  defp string_key_maps(nil), do: :null
  defp string_key_maps(true), do: true
  defp string_key_maps(false), do: false
  defp string_key_maps(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp string_key_maps(list) when is_list(list), do: Enum.map(list, &string_key_maps/1)
  defp string_key_maps(other), do: other

  defp key_to_string(key) when is_atom(key), do: Atom.to_string(key)
  defp key_to_string(key), do: to_string(key)

  defp normalize_json_nulls(:null), do: nil

  defp normalize_json_nulls(map) when is_map(map) do
    map
    |> Enum.map(fn {key, value} -> {key, normalize_json_nulls(value)} end)
    |> Map.new()
  end

  defp normalize_json_nulls(list) when is_list(list), do: Enum.map(list, &normalize_json_nulls/1)
  defp normalize_json_nulls(other), do: other
end
