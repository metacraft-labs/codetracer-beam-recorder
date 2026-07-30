defmodule CodetracerBeamRecorder.SpanStreamHelpers do
  @moduledoc """
  Shared plumbing for the RS-M8 web-request span suites
  (`plug_requests_test.exs`, `phoenix_requests_test.exs`).

  This file is **not a test suite** and is never run on its own; both suites
  `Code.require_file/2` it. It exists because the two suites need the same
  four things — locate the recorder binary, compile a demo app, record it, and
  decode the span stream — and copying two hundred lines of JSON parser into
  each of them would make a change to the span record a four-file edit.

  ## No mocks

  Nothing here fakes anything. `record!/3` runs the real recorder binary
  against a real `mix run`, and `read_spans!/2` shells out to the recorder's
  `read-spans` subcommand, which decodes `spans.dat` through
  `read_span_stream_json` — i.e. through `ct_spans_json`, the canonical Nim
  span reader that `ct print -f http` and the Request Panel's backend also
  use. The suites therefore cannot drift from the shipped decoder: a span the
  recorder writes that the real reader cannot read fails here.
  """

  import ExUnit.Assertions

  @repo_root Path.expand("../../..", __DIR__)

  def repo_root, do: @repo_root

  def recorder_binary! do
    debug = Path.join([@repo_root, "target", "debug", "codetracer-beam-recorder"])
    release = Path.join([@repo_root, "target", "release", "codetracer-beam-recorder"])

    cond do
      override = System.get_env("CODETRACER_BEAM_RECORDER_BIN") ->
        File.exists?(override) ||
          flunk("CODETRACER_BEAM_RECORDER_BIN=#{override} does not exist")

        override

      File.exists?(debug) ->
        debug

      File.exists?(release) ->
        release

      true ->
        flunk("codetracer-beam-recorder binary not built; run cargo build --locked")
    end
  end

  @doc """
  Compile a demo app.

  The Plug and Phoenix demos depend on the real `plug_cowboy` / `phoenix`
  packages. Fetching those is `scripts/prepare-web-fixtures.sh`'s job, run
  from the `test-integration` Just recipe before these suites, so the suites
  themselves never touch the network. A missing `deps/` is a hard failure with
  the command to fix it — never a skip: a green run of this suite has to mean
  the middleware was exercised against the real framework.
  """
  def compile_demo!(fixture_dir, build_root) do
    env = [{"MIX_ENV", "test"}, {"MIX_BUILD_ROOT", build_root}]

    assert File.dir?(Path.join(fixture_dir, "deps")),
           """
           #{fixture_dir}/deps is missing.

           The RS-M8 web demos are recorded against real Plug/Cowboy and Phoenix.
           Fetch them with:

               just prepare-web-fixtures

           This suite does not skip when the framework is unavailable; a green
           run must mean the middleware ran against the real thing.
           """

    {output, status} =
      System.cmd("mix", ["compile", "--warnings-as-errors"],
        cd: fixture_dir,
        env: env,
        stderr_to_stdout: true
      )

    assert status == 0, "mix compile failed for #{fixture_dir}: #{output}"
  end

  @doc """
  Record `expression` in `fixture_dir` into `out_dir` with the real recorder.

  Returns the recorder's combined stdout/stderr.
  """
  def record!(fixture_dir, out_dir, expression, opts \\ []) do
    env =
      [
        {"MIX_ENV", "test"},
        {"MIX_BUILD_ROOT", Keyword.fetch!(opts, :build_root)}
      ] ++ Keyword.get(opts, :env, [])

    {output, status} =
      System.cmd(
        recorder_binary!(),
        ["record", "--out-dir", out_dir, "--", "mix", "run", "--no-compile", "-e", expression],
        cd: fixture_dir,
        env: env,
        stderr_to_stdout: true
      )

    assert status == 0,
           """
           recorder run failed with status #{status} for #{expression}

           #{output}
           """

    output
  end

  @doc """
  Decode the recorded bundle's span stream.

  `:settled` (the default) is what the Request Panel shows — last record wins
  per span id. `:all` is every appended record in order, which is how a test
  checks that each request was published in flight *before* it was settled.
  """
  def read_spans!(out_dir, mode \\ :settled) do
    args =
      ["read-spans", "--bundle", out_dir] ++
        case mode do
          :settled -> ["--settled"]
          :all -> ["--all"]
        end

    {output, status} = System.cmd(recorder_binary!(), args, stderr_to_stdout: true)

    assert status == 0, "read-spans failed for #{out_dir} with status #{status}\n\n#{output}"

    output
    |> String.split("\n", trim: true)
    |> List.last()
    |> decode_json!()
  end

  @doc "A span's metadata as a map. The wire form is an ordered list of pairs."
  def meta(span) do
    Map.new(span["metadata"], fn [key, value] -> {key, value} end)
  end

  @doc "A span's metadata keys, in the order they were emitted."
  def meta_keys(span), do: Enum.map(span["metadata"], fn [key, _value] -> key end)

  def tmp_dir!(label) do
    nonce = System.unique_integer([:positive])
    stamp = System.system_time(:nanosecond)
    path = Path.join(System.tmp_dir!(), "codetracer-beam-recorder-#{label}-#{stamp}-#{nonce}")
    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end

  # Tiny JSON decoder, same shape as the one in plug_smoke_test.exs /
  # otp_fixture_matrix_test.exs. These suites run as bare `elixir <file>.exs`
  # scripts with no Mix project around them, so there is no `Jason` to reach
  # for.
  def decode_json!(input) do
    {value, _rest} = parse_value(skip_ws(input))
    value
  end

  defp parse_value(<<?", _rest::binary>> = input), do: parse_string(input)
  defp parse_value(<<?{, _::binary>> = input), do: parse_object(input)
  defp parse_value(<<?[, _::binary>> = input), do: parse_array(input)
  defp parse_value(<<"true", rest::binary>>), do: {true, rest}
  defp parse_value(<<"false", rest::binary>>), do: {false, rest}
  defp parse_value(<<"null", rest::binary>>), do: {nil, rest}

  defp parse_value(<<char::utf8, _::binary>> = input)
       when char in ?0..?9 or char == ?- do
    parse_number(input, "")
  end

  defp parse_object(<<?{, rest::binary>>) do
    case skip_ws(rest) do
      <<?}, after_brace::binary>> -> {%{}, after_brace}
      remainder -> parse_object_entries(remainder, %{})
    end
  end

  defp parse_object_entries(input, acc) do
    {key, after_key} = parse_string(skip_ws(input))
    <<?:, after_colon::binary>> = skip_ws(after_key)
    {value, after_value} = parse_value(skip_ws(after_colon))
    acc = Map.put(acc, key, value)

    case skip_ws(after_value) do
      <<?,, rest::binary>> -> parse_object_entries(skip_ws(rest), acc)
      <<?}, rest::binary>> -> {acc, rest}
    end
  end

  defp parse_array(<<?[, rest::binary>>) do
    case skip_ws(rest) do
      <<?], after_bracket::binary>> -> {[], after_bracket}
      remainder -> parse_array_entries(remainder, [])
    end
  end

  defp parse_array_entries(input, acc) do
    {value, after_value} = parse_value(skip_ws(input))
    acc = [value | acc]

    case skip_ws(after_value) do
      <<?,, rest::binary>> -> parse_array_entries(skip_ws(rest), acc)
      <<?], rest::binary>> -> {Enum.reverse(acc), rest}
    end
  end

  defp parse_string(<<?", rest::binary>>), do: parse_string_chars(rest, "")
  defp parse_string_chars(<<?", rest::binary>>, acc), do: {acc, rest}
  defp parse_string_chars(<<?\\, ?", rest::binary>>, acc), do: parse_string_chars(rest, acc <> "\"")

  defp parse_string_chars(<<?\\, ?\\, rest::binary>>, acc),
    do: parse_string_chars(rest, acc <> "\\")

  defp parse_string_chars(<<?\\, ?n, rest::binary>>, acc), do: parse_string_chars(rest, acc <> "\n")
  defp parse_string_chars(<<?\\, ?t, rest::binary>>, acc), do: parse_string_chars(rest, acc <> "\t")
  defp parse_string_chars(<<?\\, ?r, rest::binary>>, acc), do: parse_string_chars(rest, acc <> "\r")
  defp parse_string_chars(<<?\\, ?/, rest::binary>>, acc), do: parse_string_chars(rest, acc <> "/")

  defp parse_string_chars(<<char::utf8, rest::binary>>, acc),
    do: parse_string_chars(rest, acc <> <<char::utf8>>)

  defp parse_number(<<char::utf8, rest::binary>>, acc)
       when char in ?0..?9 or char in [?-, ?+, ?., ?e, ?E] do
    parse_number(rest, acc <> <<char::utf8>>)
  end

  defp parse_number(rest, acc) do
    if String.contains?(acc, ".") or String.contains?(acc, "e") or String.contains?(acc, "E") do
      {String.to_float(acc), rest}
    else
      {String.to_integer(acc), rest}
    end
  end

  defp skip_ws(<<char::utf8, rest::binary>>) when char in [?\s, ?\t, ?\n, ?\r],
    do: skip_ws(rest)

  defp skip_ws(input), do: input
end
