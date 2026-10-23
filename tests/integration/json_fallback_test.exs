ExUnit.start()

# The recorder's own source, loaded the way a target project's Mix build
# loads it. It also defines the Mix task modules, which need Mix loaded.
Mix.start()
Code.require_file("../../lib/codetracer_beam_recorder/elixir_source_map.ex", __DIR__)

defmodule CodetracerBeamRecorder.JsonFallbackTest do
  use ExUnit.Case, async: true

  @moduledoc """
  `JasonCompat`'s RFC 8259 fallback codec: the one a target project uses when
  it has neither `Jason` nor OTP 27's `:json`, i.e. on OTP 26, the oldest
  release the CI ecosystem matrix runs. Without it the recorder's Mix
  instrumentation died on the first compiler-trace event with
  `function :json.encode/1 is undefined (module :json is not available)`.

  The codec is called directly, so it is exercised on every OTP, not only on
  the OTP 26 leg. Where `:json` exists (OTP 27+), every case is also checked
  against it, so the fallback cannot drift from the codec it stands in for.
  Nothing is mocked.
  """

  @otp_json? Code.ensure_loaded?(:json)

  defp encode(term), do: term |> JasonCompat.fallback_encode() |> IO.iodata_to_binary()
  defp decode(text), do: JasonCompat.fallback_decode!(text)

  # {JSON text, decoded term}
  @cases [
    {~s({"a":1,"b":[true,false,null],"c":{"d":"e"}}),
     %{"a" => 1, "b" => [true, false, :null], "c" => %{"d" => "e"}}},
    {~s([]), []},
    {~s({}), %{}},
    {~s([[[]],{}]), [[[]], %{}]},
    {~s(-0), 0},
    {~s(12345678901234567890), 12_345_678_901_234_567_890},
    {~s(-12.5), -12.5},
    {~s(1e3), 1.0e3},
    {~s(2.5E-2), 0.025},
    {~s(-1.5e+2), -150.0},
    {~s("quote \\" backslash \\\\ slash \\/"), ~s(quote " backslash \\ slash /)},
    {~s("\\b\\f\\n\\r\\t"), "\b\f\n\r\t"},
    {~s("\\u0000\\u001f\\u00e9"), <<0, 0x1F>> <> "é"},
    {~s("\\ud83d\\ude00"), "😀"},
    {~s("raw utf-8: é 😀"), "raw utf-8: é 😀"}
  ]

  test "decodes every RFC 8259 value form" do
    for {text, expected} <- @cases do
      assert decode(text) === expected, "decoding #{text}"
      if @otp_json?, do: assert(apply(:json, :decode, [text]) === expected, ":json on #{text}")
    end
  end

  test "insignificant whitespace is allowed around every token" do
    assert decode(" \t\n\r{ \"a\" : [ 1 , 2 ] , \"b\" : null } \n") ==
             %{"a" => [1, 2], "b" => :null}
  end

  test "encoded values decode back to the same term" do
    terms = [
      %{"nested" => %{"list" => [1, -2, 3.25, "x", :null, true, false]}},
      ["control \u0001 chars \n\t", "quote \" and \\ backslash", "é 😀"],
      0.1,
      -0.0,
      1.0e300,
      123_456_789_012_345_678
    ]

    for term <- terms do
      text = encode(term)
      assert decode(text) === term, "round trip of #{inspect(term)} via #{text}"

      if @otp_json? do
        assert apply(:json, :decode, [text]) === term, ":json reading #{text}"
        assert decode(IO.iodata_to_binary(apply(:json, :encode, [term]))) === term
      end
    end
  end

  test "encodes exactly what the readers of the recorder's files expect" do
    assert encode(%{"k" => [1, 2.5, "s", :null, true]}) == ~s({"k":[1,2.5,"s",null,true]})
    assert encode("a\"b\\c\nd\u0001") == ~s("a\\"b\\\\c\\nd\\u0001")
    assert encode(:atom_value) == ~s("atom_value")
    assert encode(%{key: 1}) == ~s({"key":1})
  end

  test "JasonCompat output decodes the same through the public API" do
    term = %{file: "lib/a.ex", line: 3, context: nil, flags: [true, false]}
    expected = %{"file" => "lib/a.ex", "line" => 3, "context" => nil, "flags" => [true, false]}
    assert term |> JasonCompat.encode!() |> JasonCompat.decode!() == expected
  end

  test "rejects malformed JSON instead of guessing" do
    for bad <- [
          "",
          "{",
          "[1,]",
          "{\"a\" 1}",
          "{a:1}",
          "01",
          "1.",
          ".5",
          "\"unterminated",
          "\"bad \\x escape\"",
          "\"lone \\ud800 surrogate\"",
          "\"raw \n newline\"",
          "nul",
          "1e400",
          "[-1e400]",
          "[1] trailing",
          <<?", 0xFF, ?">>
        ] do
      try do
        flunk("decoding #{inspect(bad)} returned #{inspect(decode(bad))} instead of raising")
      rescue
        error in ArgumentError -> assert Exception.message(error) =~ "invalid JSON"
      end
    end
  end

  test "refuses to encode what JSON cannot represent" do
    assert_raise ArgumentError, ~r/not valid UTF-8/, fn -> encode(<<0xFF>>) end
    assert_raise ArgumentError, ~r/cannot encode/, fn -> encode({:tuple}) end
  end
end
