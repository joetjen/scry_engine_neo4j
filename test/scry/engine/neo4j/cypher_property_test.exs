defmodule Scry.Engine.Neo4j.CypherPropertyTest do
  @moduledoc """
  Property coverage for `Cypher.quote_identifier/1` -- the invariant a
  real backtick-quoted Cypher identifier depends on: *every* literal
  backtick in the input comes back doubled, the result is always
  wrapped in exactly one leading and one trailing backtick, and an
  input with no backtick at all round-trips with only the wrapping
  added. AGENTS.md calls for a property test here rather than
  enumerating hand-picked examples, since an edge/relationship-type
  name is arbitrary user-controlled text once VIA's own `edge` argument
  is considered.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Scry.Engine.Neo4j.Cypher

  property "every literal backtick in the input is doubled in the output" do
    check all(text <- StreamData.string(:printable, max_length: 30)) do
      quoted = Cypher.quote_identifier(text)
      inner = String.slice(quoted, 1..-2//1)

      original_backtick_count = text |> String.graphemes() |> Enum.count(&(&1 == "`"))
      doubled_backtick_count = inner |> String.graphemes() |> Enum.count(&(&1 == "`"))

      assert doubled_backtick_count == original_backtick_count * 2
    end
  end

  property "the result is always wrapped in exactly one leading and trailing backtick" do
    check all(text <- StreamData.string(:printable, max_length: 30)) do
      quoted = Cypher.quote_identifier(text)
      assert String.starts_with?(quoted, "`")
      assert String.ends_with?(quoted, "`")
    end
  end

  property "an identifier with no backtick at all round-trips with only the wrapping added" do
    check all(text <- StreamData.string(:printable, max_length: 30)) do
      text = String.replace(text, "`", "")
      assert Cypher.quote_identifier(text) == "`" <> text <> "`"
    end
  end
end
