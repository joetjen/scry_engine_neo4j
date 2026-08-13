defmodule Scry.Engine.Neo4jTest do
  @moduledoc """
  `Scry.Engine.Neo4j` -- confirms `execute/3` answers an ordinary flat
  query (no `VIA`/`PATH`) entirely via `Scry.Core.QueryOps.run_flat/3`
  over fetched node properties, that `VIA` (default one hop, `HOPS`,
  `BACKWARD`, `SHORTEST`, and each of `WHERE`/`ORDER BY`/`DISTINCT`/
  `LIMIT`/`OFFSET`) translates into a real Cypher traversal and composes
  correctly with a real cyclic graph (confirmed: no path ever revisits a
  node, `Scry.Engine.Neo4j.Cypher`'s own moduledoc has the finding this
  guards against), that `PATH` resolves to the full traversal's own node
  rows inside a `VIA` body and declines outside one, that more than one
  `VIA` in the same body numbers `"via_1"`/`"via_2"`, that a nested `VIA`
  works (falls out of the recursive design for free), that `VIA`/`PATH`
  combined with `GROUP BY` declines, and that a nested correlated
  `SELECT` and `describe_source/2` both work end to end against a real
  `neo4j:5-community` container -- not just plausible-looking output.

  **Requires a real, reachable Neo4j instance** -- run one locally via
  `docker run -d --name scry-neo4j -p 7687:7687 -e
  NEO4J_AUTH=neo4j/scrytest123 neo4j:5-community`. Runs `async: false`
  -- every test shares one real server and a small, fixed graph, torn
  down and rebuilt in `setup_all`.

      # alice --knows--> bob --knows--> carol
      #   \\--knows--> dave --knows--> carol
      # carol --knows--> alice (a cycle, back to the start)

  The identical fixture shape `scry_graph`'s own reference `Executor`
  test suite already uses (`Scry.Graph.ExecutorTest`) -- deliberate, so
  `test/scry/engine/neo4j/parity_test.exs` can run the exact same parsed
  queries against both a real Neo4j-backed graph and the reference's own
  in-memory one and compare results directly (AGENTS.md's "Parity
  between multiple implementations" rule).
  """

  use ExUnit.Case, async: false

  alias Scry.Core.{CombinedQuery, Query}
  alias Scry.Engine.Neo4j, as: Engine
  alias Scry.Engine.Neo4j.Conn

  @auth [auth: [username: "neo4j", password: "scrytest123"]]

  setup_all do
    {:ok, conn} = Conn.open(@auth)
    seed!(conn)
    %{conn: conn}
  end

  defp seed!(conn) do
    {:ok, _} = Conn.query(conn, "MATCH (n) DETACH DELETE n")

    {:ok, _} =
      Conn.query(conn, """
      CREATE (a:Person {name: 'Alice', age: 30})
      CREATE (b:Person {name: 'Bob', age: 35})
      CREATE (c:Person {name: 'Carol', age: 40})
      CREATE (d:Person {name: 'Dave', age: 28})
      CREATE (a)-[:knows]->(b)
      CREATE (a)-[:knows]->(d)
      CREATE (b)-[:knows]->(c)
      CREATE (d)-[:knows]->(c)
      CREATE (c)-[:knows]->(a)
      """)
  end

  defp materialize({:ok, rows}), do: {:ok, rows |> Enum.to_list()}
  defp materialize(other), do: other

  defp via_opts(overrides \\ %{}) do
    Map.merge(
      %{
        shortest: false,
        backward: false,
        hops: nil,
        where: nil,
        distinct: false,
        order_bys: [],
        limit: nil,
        offset: nil
      },
      overrides
    )
  end

  describe "flat queries -- no VIA/PATH, delegate entirely to Scry.Core.QueryOps.run_flat/3" do
    test "ordinary WHERE + plain fields, no VIA at all", %{conn: conn} do
      query = %Query{
        source: ["Person"],
        wheres: [{:cmp, :gt, ["age"], 32}],
        select: [{:field, ["name"]}]
      }

      assert {:ok, rows} = materialize(Engine.execute(conn, query, %{}))
      assert rows |> Enum.map(& &1["name"]) |> Enum.sort() == ["Bob", "Carol"]
    end

    test "ORDER BY + LIMIT compose", %{conn: conn} do
      query = %Query{
        source: ["Person"],
        order_bys: [{{:field, ["age"]}, :desc}],
        limit: 2,
        select: [{:field, ["name"]}]
      }

      assert {:ok, rows} = materialize(Engine.execute(conn, query, %{}))
      assert Enum.map(rows, & &1["name"]) == ["Carol", "Bob"]
    end

    test "GROUP BY/aggregate works generically over fetched node properties", %{conn: conn} do
      query = %Query{
        source: ["Person"],
        select: [{:computed, "total", {:call, "count", [{:field, ["name"]}]}}]
      }

      assert {:ok, [row]} = materialize(Engine.execute(conn, query, %{}))
      assert row["total"] == 4
    end

    test "a label matching no node at all is an empty result, not an error", %{conn: conn} do
      query = %Query{source: ["Nonexistent"], select: [{:field, ["name"]}]}
      assert {:ok, []} = materialize(Engine.execute(conn, query, %{}))
    end
  end

  describe "VIA -- default one hop, forward" do
    test "reaches every direct neighbor via the named edge", %{conn: conn} do
      query = %Query{
        source: ["Person"],
        wheres: [{:cmp, :eq, ["name"], "Alice"}],
        select: [{:variant, {:via, ["knows"], via_opts(), [{:field, ["name"]}]}}]
      }

      assert {:ok, [row]} = materialize(Engine.execute(conn, query, %{}))
      assert row["via"] |> Enum.map(& &1["name"]) |> Enum.sort() == ["Bob", "Dave"]
    end

    test "an edge name with no outgoing matches at all resolves to an empty list, not an error",
         %{conn: conn} do
      query = %Query{
        source: ["Person"],
        wheres: [{:cmp, :eq, ["name"], "Dave"}],
        select: [{:variant, {:via, ["likes"], via_opts(), [{:field, ["name"]}]}}]
      }

      assert {:ok, [row]} = materialize(Engine.execute(conn, query, %{}))
      assert row["via"] == []
    end
  end

  describe "HOPS -- bounded-depth traversal" do
    test "HOPS 2..2 reaches only two-hop neighbors, not one-hop ones", %{conn: conn} do
      query = %Query{
        source: ["Person"],
        wheres: [{:cmp, :eq, ["name"], "Alice"}],
        select: [{:variant, {:via, ["knows"], via_opts(%{hops: {2, 2}}), [{:field, ["name"]}]}}]
      }

      assert {:ok, [row]} = materialize(Engine.execute(conn, query, %{}))
      # carol is reachable at depth 2 via both bob and dave -- two
      # distinct paths, both surfaced (no DISTINCT/SHORTEST here).
      assert Enum.map(row["via"], & &1["name"]) == ["Carol", "Carol"]
    end

    test "HOPS 1..2 reaches both one- and two-hop neighbors", %{conn: conn} do
      query = %Query{
        source: ["Person"],
        wheres: [{:cmp, :eq, ["name"], "Alice"}],
        select: [{:variant, {:via, ["knows"], via_opts(%{hops: {1, 2}}), [{:field, ["name"]}]}}]
      }

      assert {:ok, [row]} = materialize(Engine.execute(conn, query, %{}))

      assert Enum.map(row["via"], & &1["name"]) |> Enum.sort() == [
               "Bob",
               "Carol",
               "Carol",
               "Dave"
             ]
    end

    test "cycle avoidance -- a path never revisits a node already in it, so HOPS doesn't loop forever",
         %{conn: conn} do
      query = %Query{
        source: ["Person"],
        wheres: [{:cmp, :eq, ["name"], "Alice"}],
        select: [{:variant, {:via, ["knows"], via_opts(%{hops: {1, 10}}), [{:field, ["name"]}]}}]
      }

      assert {:ok, [row]} = materialize(Engine.execute(conn, query, %{}))
      refute "Alice" in Enum.map(row["via"], & &1["name"])
    end
  end

  describe "BACKWARD -- traverses incoming edges instead of outgoing" do
    test "reaches every node with an edge pointing at the start node", %{conn: conn} do
      query = %Query{
        source: ["Person"],
        wheres: [{:cmp, :eq, ["name"], "Carol"}],
        select: [
          {:variant, {:via, ["knows"], via_opts(%{backward: true}), [{:field, ["name"]}]}}
        ]
      }

      assert {:ok, [row]} = materialize(Engine.execute(conn, query, %{}))
      assert Enum.map(row["via"], & &1["name"]) |> Enum.sort() == ["Bob", "Dave"]
    end
  end

  describe "SHORTEST -- keeps only a minimum-depth path per reached node" do
    test "a node reachable by both a 1-hop and a longer path keeps only the shortest", %{
      conn: conn
    } do
      # Carol is reachable from Alice via bob/dave (2 hops) and, via the
      # cycle edge, indirectly by a longer route -- SHORTEST keeps only
      # the 2-hop arrivals.
      query = %Query{
        source: ["Person"],
        wheres: [{:cmp, :eq, ["name"], "Alice"}],
        select: [
          {:variant,
           {:via, ["knows"], via_opts(%{shortest: true, hops: {1, 10}}), [{:field, ["name"]}]}}
        ]
      }

      assert {:ok, [row]} = materialize(Engine.execute(conn, query, %{}))
      assert Enum.map(row["via"], & &1["name"]) |> Enum.sort() == ["Bob", "Carol", "Dave"]
    end
  end

  describe "VIA's own WHERE/ORDER BY/DISTINCT/LIMIT/OFFSET -- generic, not pushed to Cypher" do
    test "WHERE filters candidate end nodes by their own raw properties", %{conn: conn} do
      query = %Query{
        source: ["Person"],
        wheres: [{:cmp, :eq, ["name"], "Alice"}],
        select: [
          {:variant,
           {:via, ["knows"], via_opts(%{where: {:cmp, :gt, ["age"], 30}}), [{:field, ["name"]}]}}
        ]
      }

      assert {:ok, [row]} = materialize(Engine.execute(conn, query, %{}))
      assert Enum.map(row["via"], & &1["name"]) == ["Bob"]
    end

    test "ORDER BY sorts candidates before DISTINCT/LIMIT/OFFSET apply", %{conn: conn} do
      query = %Query{
        source: ["Person"],
        wheres: [{:cmp, :eq, ["name"], "Alice"}],
        select: [
          {:variant,
           {:via, ["knows"], via_opts(%{hops: {1, 2}, order_bys: [{{:field, ["age"]}, :asc}]}),
            [{:field, ["name"]}]}}
        ]
      }

      assert {:ok, [row]} = materialize(Engine.execute(conn, query, %{}))
      # bob(35) reached at 1 hop, dave(28) at 1 hop, carol(40) at 2 hops
      # (twice, once via each parent) -- ascending age.
      assert Enum.map(row["via"], & &1["name"]) == ["Dave", "Bob", "Carol", "Carol"]
    end

    test "DISTINCT dedupes the final projected rows, LIMIT/OFFSET apply after", %{conn: conn} do
      query = %Query{
        source: ["Person"],
        wheres: [{:cmp, :eq, ["name"], "Alice"}],
        select: [
          {:variant,
           {:via, ["knows"],
            via_opts(%{
              hops: {1, 2},
              distinct: true,
              order_bys: [{{:field, ["name"]}, :asc}]
            }), [{:field, ["name"]}]}}
        ]
      }

      assert {:ok, [row]} = materialize(Engine.execute(conn, query, %{}))
      # carol appears twice among raw candidates (via bob and via dave)
      # but DISTINCT dedupes it down to one, since both instances
      # project to the same {"name" => "Carol"} row.
      assert Enum.map(row["via"], & &1["name"]) == ["Bob", "Carol", "Dave"]
    end

    test "LIMIT/OFFSET without DISTINCT apply to the final projected rows in order", %{
      conn: conn
    } do
      query = %Query{
        source: ["Person"],
        wheres: [{:cmp, :eq, ["name"], "Alice"}],
        select: [
          {:variant,
           {:via, ["knows"],
            via_opts(%{
              hops: {1, 2},
              order_bys: [{{:field, ["name"]}, :asc}],
              offset: 1,
              limit: 2
            }), [{:field, ["name"]}]}}
        ]
      }

      assert {:ok, [row]} = materialize(Engine.execute(conn, query, %{}))
      assert Enum.map(row["via"], & &1["name"]) == ["Carol", "Carol"]
    end
  end

  describe "PATH -- the full traversal's own node rows, start through end inclusive" do
    test "resolves inside a VIA body", %{conn: conn} do
      query = %Query{
        source: ["Person"],
        wheres: [{:cmp, :eq, ["name"], "Alice"}],
        select: [
          {:variant,
           {:via, ["knows"], via_opts(%{hops: {2, 2}}), [{:field, ["name"]}, {:variant, :path}]}}
        ]
      }

      assert {:ok, [row]} = materialize(Engine.execute(conn, query, %{}))
      assert length(row["via"]) == 2

      Enum.each(row["via"], fn via_row ->
        assert via_row["name"] == "Carol"
        path_names = Enum.map(via_row["path"], & &1["name"])
        assert List.first(path_names) == "Alice"
        assert List.last(path_names) == "Carol"
        assert length(path_names) == 3
      end)
    end

    test "declines outside any enclosing VIA", %{conn: conn} do
      query = %Query{source: ["Person"], select: [{:variant, :path}]}

      assert {:error, {:unsupported, :path_outside_via}} =
               materialize(Engine.execute(conn, query, %{}))
    end
  end

  describe "more than one VIA in the same body" do
    test "numbers via_1/via_2 in order of appearance", %{conn: conn} do
      query = %Query{
        source: ["Person"],
        wheres: [{:cmp, :eq, ["name"], "Alice"}],
        select: [
          {:variant, {:via, ["knows"], via_opts(), [{:field, ["name"]}]}},
          {:variant, {:via, ["knows"], via_opts(%{backward: true}), [{:field, ["name"]}]}}
        ]
      }

      assert {:ok, [row]} = materialize(Engine.execute(conn, query, %{}))
      refute Map.has_key?(row, "via")
      assert row["via_1"] |> Enum.map(& &1["name"]) |> Enum.sort() == ["Bob", "Dave"]
      # Alice has no incoming `knows` edge except the cycle from carol.
      assert row["via_2"] |> Enum.map(& &1["name"]) == ["Carol"]
    end
  end

  describe "nested VIA -- a VIA inside another VIA's own inner body" do
    test "resolves one hop relative to each outer candidate, recursively", %{conn: conn} do
      query = %Query{
        source: ["Person"],
        wheres: [{:cmp, :eq, ["name"], "Alice"}],
        select: [
          {:variant,
           {:via, ["knows"], via_opts(),
            [
              {:field, ["name"]},
              {:variant, {:via, ["knows"], via_opts(), [{:field, ["name"]}]}}
            ]}}
        ]
      }

      assert {:ok, [row]} = materialize(Engine.execute(conn, query, %{}))
      by_name = Map.new(row["via"], fn r -> {r["name"], Enum.map(r["via"], & &1["name"])} end)
      assert by_name["Bob"] == ["Carol"]
      assert by_name["Dave"] == ["Carol"]
    end
  end

  describe "VIA/PATH combined with GROUP BY" do
    test "declines outright", %{conn: conn} do
      query = %Query{
        source: ["Person"],
        group_bys: [["name"]],
        select: [{:variant, {:via, ["knows"], via_opts(), [{:field, ["name"]}]}}]
      }

      assert {:error, {:unsupported, :via_with_group_by}} =
               materialize(Engine.execute(conn, query, %{}))
    end
  end

  describe "a nested correlated SELECT sibling of an ordinary field" do
    test "correlates to the top-level source's own row", %{conn: conn} do
      nested = %Query{
        source: ["Person"],
        wheres: [{:cmp, :eq, ["age"], {:field, ["Person", "age"]}}],
        select: [{:field, ["name"]}]
      }

      query = %Query{
        source: ["Person"],
        wheres: [{:cmp, :eq, ["name"], "Alice"}],
        select: [{:field, ["name"]}, nested]
      }

      assert {:ok, [row]} = materialize(Engine.execute(conn, query, %{}))
      assert row["name"] == "Alice"
      assert Enum.map(row["Person"], & &1["name"]) == ["Alice"]
    end
  end

  describe "%Scry.Core.CombinedQuery{} and a WITH-bound source" do
    test "CombinedQuery delegates to Scry.Core.QueryOps.run_document/4", %{conn: conn} do
      left = %Query{
        source: ["Person"],
        wheres: [{:cmp, :eq, ["name"], "Alice"}],
        select: [{:field, ["name"]}]
      }

      right = %Query{
        source: ["Person"],
        wheres: [{:cmp, :eq, ["name"], "Bob"}],
        select: [{:field, ["name"]}]
      }

      combined = %CombinedQuery{op: :union, left: left, right: right}

      assert {:ok, rows} = materialize(Engine.execute(conn, combined, %{}))
      assert rows |> Enum.map(& &1["name"]) |> Enum.sort() == ["Alice", "Bob"]
    end

    test "a WITH-bound top-level source runs the binding instead of a real label", %{conn: conn} do
      binding = %Query{
        source: ["Person"],
        wheres: [{:cmp, :eq, ["name"], "Alice"}],
        select: [{:field, ["name"]}]
      }

      query = %Query{
        source: ["only_alice"],
        with_bindings: %{"only_alice" => binding},
        select: [{:field, ["name"]}]
      }

      assert {:ok, rows} = materialize(Engine.execute(conn, query, %{}))
      assert Enum.map(rows, & &1["name"]) == ["Alice"]
    end
  end

  describe "describe_source/2" do
    test "reports every observed property on the given label", %{conn: conn} do
      assert {:ok, fields} = Engine.describe_source(conn, "Person")
      by_name = Map.new(fields, &{&1.name, &1})

      assert by_name["name"].scalar == :string
      assert by_name["age"].scalar == :integer
      assert by_name["name"].nullable == false
      assert by_name["age"].nullable == false
    end

    test "a label with no observed properties at all is not found", %{conn: conn} do
      assert {:error, :not_found} = Engine.describe_source(conn, "NoSuchLabel")
    end
  end
end
