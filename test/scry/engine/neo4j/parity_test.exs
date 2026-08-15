defmodule Scry.Engine.Neo4j.ParityTest do
  @moduledoc """
  AGENTS.md's "Parity between multiple implementations" rule, applied
  directly: `scry_graph`'s own reference `Scry.Graph.Executor` (a naive
  recursive-DFS path enumerator over an in-memory graph) and this
  package's `Scry.Engine.Neo4j` (a real Cypher-backed adapter) are two
  implementations of the identical `VIA`/`PATH` semantics. Rather than
  asserting each package's own output looks
  plausible in isolation, this suite parses one query text *once*
  (`Scry.Graph.parse/1`, the same grammar/AST both engines are handed),
  then runs the exact same `%Scry.Core.Query{}` against a byte-for-byte
  identical fixture graph in both a real Neo4j container and the
  reference's own in-memory `Scry.Graph.Conn`, and asserts the
  *projected values* agree -- not full-row equality, since the
  reference fixture carries its own synthetic `"id"` property (required
  by its own `Conn`) that a real Neo4j node has no equivalent for, so
  every query here selects only ordinary fields (`name`/`age`), never
  `"id"`.
  """

  use ExUnit.Case, async: false

  alias Scry.Core.Cursor
  alias Scry.Engine.Neo4j, as: RealEngine
  alias Scry.Engine.Neo4j.Conn, as: RealConn
  alias Scry.Graph.Conn, as: RefConn
  alias Scry.Graph.Executor, as: RefEngine

  @auth [auth: [username: "neo4j", password: "scrytest123"]]

  setup_all do
    {:ok, real_conn} = RealConn.open(@auth)
    seed_real!(real_conn)
    %{real_conn: real_conn, ref_conn: fixture_ref_conn()}
  end

  # alice --knows--> bob --knows--> carol
  #   \--knows--> dave --knows--> carol
  # carol --knows--> alice (a cycle, back to the start)
  # -- the identical fixture `Scry.Graph.ExecutorTest`'s own
  # `fixture_conn/0` uses, node for node, edge for edge.
  defp fixture_ref_conn do
    RefConn.new(
      %{
        ["Person"] => [
          %{"id" => "alice", "name" => "Alice", "age" => 30},
          %{"id" => "bob", "name" => "Bob", "age" => 35},
          %{"id" => "carol", "name" => "Carol", "age" => 40},
          %{"id" => "dave", "name" => "Dave", "age" => 28}
        ]
      },
      %{
        {"alice", "knows"} => ["bob", "dave"],
        {"bob", "knows"} => ["carol"],
        {"dave", "knows"} => ["carol"],
        {"carol", "knows"} => ["alice"]
      }
    )
  end

  defp seed_real!(conn) do
    {:ok, _} = RealConn.query(conn, "MATCH (n) DETACH DELETE n")

    {:ok, _} =
      RealConn.query(conn, """
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

  defp run_both(source, ref_conn, real_conn) do
    {:ok, query} = Scry.Graph.parse(source)
    {:ok, ref_cursor} = RefEngine.run(query, ref_conn)
    {:ok, real_enumerable} = RealEngine.execute(real_conn, query, %{})
    {Cursor.to_list(ref_cursor), Enum.to_list(real_enumerable)}
  end

  defp via_names(rows),
    do: rows |> Enum.map(& &1["via"]) |> Enum.map(&Enum.map(&1, fn r -> r["name"] end))

  # `:order_sensitive` queries have an explicit `ORDER BY` (or a single,
  # unambiguous match) -- compared as an exact sequence. `:sorted`
  # queries have no `ORDER BY` at all, so *which* order multiple
  # equally-valid candidates come back in is never a contract either
  # engine makes -- Cypher's own `MATCH` and the reference's own
  # `Map.get(adjacency, ...)` traversal have no reason to agree on
  # enumeration order, only on *which* candidates exist and how many
  # times each does -- compared sorted, duplicates included. `:dedup_sorted`
  # is `SHORTEST`'s own real, stated tie-handling divergence (see the
  # one list entry using it, below, for the full reasoning) -- same set
  # of reached names, ties collapsed on both sides, not full agreement.
  for {label, query_text, comparison} <- [
        {"default one hop, forward",
         ~s(SELECT Person WHERE name = "Alice" { via knows { name } }), :sorted},
        {"HOPS 2-2", ~s(SELECT Person WHERE name = "Alice" { via knows HOPS 2-2 { name } }),
         :sorted},
        {"HOPS 1-10, cycle avoidance",
         ~s(SELECT Person WHERE name = "Alice" { via knows HOPS 1-10 { name } }), :sorted},
        {"BACKWARD", ~s(SELECT Person WHERE name = "Carol" { via knows BACKWARD { name } }),
         :sorted},
        # Carol is reachable from Alice by two equally-short (2-hop)
        # paths, via bob and via dave -- a real tie. The reference's own
        # `keep_shortest/1` keeps *both* tied paths; Neo4j's `SHORTEST 1`
        # keeps exactly one path per end node, a real, stated scope
        # limit (`Scry.Engine.Neo4j.Cypher`'s own moduledoc has the full
        # "why", including the one syntax candidate for "all ties" that
        # couldn't be confirmed safe to use). `:dedup_sorted` -- same
        # *set* of reached names, ties collapsed on both sides -- is the
        # invariant that still genuinely holds here, not full agreement.
        {"SHORTEST HOPS 1-10",
         ~s(SELECT Person WHERE name = "Alice" { via knows SHORTEST HOPS 1-10 { name } }),
         :dedup_sorted},
        {"WHERE inside VIA",
         ~s(SELECT Person WHERE name = "Alice" { via knows WHERE name = "Bob" { name } }),
         :order_sensitive},
        {"DISTINCT collapses identical projections",
         ~s(SELECT Person WHERE name = "Alice" { via knows HOPS 2-2 DISTINCT { name } }),
         :order_sensitive},
        {"ORDER BY inside VIA",
         ~s(SELECT Person WHERE name = "Alice" { via knows HOPS 1-2 ORDER BY age { name } }),
         :order_sensitive}
      ] do
    test "#{label} -- reference and real engine agree", %{
      real_conn: real_conn,
      ref_conn: ref_conn
    } do
      {ref_rows, real_rows} = run_both(unquote(query_text), ref_conn, real_conn)
      ref_names = via_names(ref_rows)
      real_names = via_names(real_rows)

      case unquote(comparison) do
        :order_sensitive ->
          assert ref_names == real_names

        :sorted ->
          assert Enum.map(ref_names, &Enum.sort/1) == Enum.map(real_names, &Enum.sort/1)

        :dedup_sorted ->
          dedup_sort = fn lists -> Enum.map(lists, &(&1 |> Enum.uniq() |> Enum.sort())) end
          assert dedup_sort.(ref_names) == dedup_sort.(real_names)
      end
    end
  end

  test "PATH inside VIA agrees on the full traversal's own node names", %{
    real_conn: real_conn,
    ref_conn: ref_conn
  } do
    {ref_rows, real_rows} =
      run_both(
        ~s(SELECT Person WHERE name = "Alice" { via knows HOPS 2-2 { name, PATH } }),
        ref_conn,
        real_conn
      )

    # No `ORDER BY`/`SHORTEST` here (`HOPS 2-2` alone), so -- same
    # reasoning as the `:sorted` comparisons above -- only *which* full
    # paths exist is a contract, not the order they come back in.
    path_names = fn rows ->
      rows
      |> Enum.map(& &1["via"])
      |> Enum.map(fn via_rows -> Enum.map(via_rows, & &1["path"]) end)
      |> Enum.map(fn paths -> Enum.map(paths, fn path -> Enum.map(path, & &1["name"]) end) end)
      |> Enum.map(&Enum.sort/1)
    end

    assert path_names.(ref_rows) == path_names.(real_rows)
  end

  test "an ordinary top-level WHERE with no VIA at all agrees", %{
    real_conn: real_conn,
    ref_conn: ref_conn
  } do
    {ref_rows, real_rows} =
      run_both(~s(SELECT Person WHERE age > 32 { name }), ref_conn, real_conn)

    names = fn rows -> rows |> Enum.map(& &1["name"]) |> Enum.sort() end
    assert names.(ref_rows) == names.(real_rows)
  end
end
