defmodule Scry.Engine.Neo4j.CypherTest do
  use ExUnit.Case, async: true

  alias Scry.Engine.Neo4j.Cypher

  describe "quote_identifier/1" do
    test "wraps a plain identifier in backticks" do
      assert Cypher.quote_identifier("KNOWS") == "`KNOWS`"
    end

    test "doubles a literal backtick inside the identifier" do
      assert Cypher.quote_identifier("weird`edge") == "`weird``edge`"
    end
  end

  describe "via_match_query/4" do
    test "forward, non-shortest" do
      cypher = Cypher.via_match_query(["knows"], {1, 3}, false, false)

      assert cypher =~ "MATCH (start) WHERE elementId(start) = $start_id"
      assert cypher =~ "MATCH p = (start)-[:`knows`*1..3]->(end)"
      refute cypher =~ "SHORTEST"
      assert cypher =~ "WHERE ALL(n IN nodes(p) WHERE size([x IN nodes(p) WHERE x = n]) = 1)"
      assert cypher =~ "RETURN end, nodes(p) AS path_nodes"
    end

    test "backward direction reverses the arrow" do
      cypher = Cypher.via_match_query(["knows"], {1, 1}, true, false)
      assert cypher =~ "MATCH p = (start)<-[:`knows`*1..1]-(end)"
    end

    test "shortest prefixes the pattern with SHORTEST 1" do
      cypher = Cypher.via_match_query(["knows"], {1, 5}, false, true)
      assert cypher =~ "MATCH p = SHORTEST 1 (start)-[:`knows`*1..5]->(end)"
    end

    test "a multi-segment edge path joins with a dot before quoting" do
      cypher = Cypher.via_match_query(["a", "b"], {1, 1}, false, false)
      assert cypher =~ "[:`a.b`*1..1]"
    end
  end

  describe "fetch_label_query/1" do
    test "quotes the label" do
      assert Cypher.fetch_label_query("Person") == "MATCH (n:`Person`) RETURN n"
    end
  end
end
