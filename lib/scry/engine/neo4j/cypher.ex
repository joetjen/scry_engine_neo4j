defmodule Scry.Engine.Neo4j.Cypher do
  @moduledoc """
  The one piece of real Cypher generation `Scry.Engine.Neo4j` needs --
  building the `MATCH`/traversal shape for one `VIA <edge> [modifiers]`
  item. Everything else `VIA`'s own `opts` can carry
  (`WHERE`/`ORDER BY`/`DISTINCT`/`LIMIT`/`OFFSET`) is deliberately *not*
  translated here at all -- `Scry.Engine.Neo4j.resolve_via/7`'s own
  moduledoc has the full reasoning, but in short: those all apply
  generically, via `Scry.Core.QueryOps.run_flat/3`, over whatever
  candidate rows this module's own query returns, the identical
  "reference-engine's own predicate evaluator, not a hand-rolled
  translator" posture `scry_graph`'s reference `Executor` already uses
  for the same fields. That leaves exactly one thing a real backend
  needs to contribute over the reference's own naive recursive DFS:
  which paths *exist* at all -- hop-bounded traversal, direction,
  and (optionally) shortest-path pruning -- which is what this module
  generates.

  ## Two things confirmed directly against a real `neo4j:5-community`
  container before writing this, not assumed from documentation

  - **Cypher's variable-length relationship pattern does not enforce
    simple-path semantics by default** -- `-[:KNOWS*1..6]->` happily
    revisits an already-visited *node* within the same path (only
    relationship reuse is disallowed), a real, confirmed divergence
    from `scry_graph`'s own reference `enumerate_paths/5` (a genuine
    simple-path DFS, "no revisiting a node within the same path" by
    construction). Left unfixed, a graph containing any cycle at all
    would silently return paths the reference implementation could
    never produce. Fixed with a standard, plugin-free Cypher idiom --
    `WHERE ALL(n IN nodes(p) WHERE size([x IN nodes(p) WHERE x = n])
    = 1)` -- confirmed, with the exact same cyclic graph, to restore
    simple-path semantics exactly (zero revisiting paths returned,
    where the unfiltered form returned several) and to compose cleanly
    with `SHORTEST 1`.
  - **The modern, GQL-conformant `SHORTEST 1` clause (no `CYPHER 25`
    version prefix needed -- confirmed this server only accepts Cypher
    version `5`, its own calendar-versioned default) is the right fit
    for `opts.shortest`, not the older `shortestPath()` function.**
    `MATCH p = SHORTEST 1 (start)-[:EDGE*min..max]->(end)`, with no
    bound on `end`, returns one shortest path to *every* reachable
    node in a single query -- exactly `scry_graph`'s own `keep_shortest/1`
    semantics (shortest-to-everywhere, not shortest-between-two-named-
    endpoints, which is what `shortestPath()` alone is built for). **One
    stated, deliberate divergence**: `SHORTEST 1` returns exactly one
    path per reachable end node, while the reference's own
    `keep_shortest/1` keeps *every* path tied for minimum length to the
    same end node. Neo4j 5.26 community's own GQL grammar has no
    plugin-free equivalent to "all ties" that composes safely (the one
    syntax candidate found, `SHORTEST 1 GROUPS`, could not be confirmed
    -- an unrelated `boltx` connection-crash bug, this module's own
    sibling `Scry.Engine.Neo4j.Conn`'s moduledoc has the full story,
    was hit before it could be verified, and re-triggering that bug
    class for an edge-case tie-break wasn't worth it) -- documented
    here and in the package README as a real, stated scope limit, not
    silently different behavior.
  """

  @doc """
  Backtick-quotes `name` for use as a Cypher relationship-type
  identifier (labels and relationship types can't be bound as query
  parameters at all -- a real, confirmed Neo4j/Cypher limitation, not
  an oversight here), escaping any literal backtick by doubling it, the
  same escaping rule Cypher's own backtick-quoted identifiers use.
  """
  @spec quote_identifier(String.t()) :: String.t()
  def quote_identifier(name) when is_binary(name) do
    "`" <> String.replace(name, "`", "``") <> "`"
  end

  @doc """
  Builds the Cypher text for one `VIA` item's own traversal -- binds
  `start` by its real Neo4j `elementId` (`$start_id`, always a bound
  parameter, supplied separately by the caller), matches every simple
  path of length in `hops` (`{min, max}`) along `edge` (a dotted-joined,
  backtick-quoted relationship type, mirroring `scry_graph`'s own
  reference `Enum.join(edge, ".")` normalization), `backward?` reversing
  the pattern's own direction (incoming edges instead of outgoing), and
  `shortest?` prefixing the match with `SHORTEST 1` (this module's own
  moduledoc has the "one path per end node, not every tie" scope note).
  Returns `end` (the candidate node) and `nodes(p)` (the full ordered
  path, start through end inclusive -- `PATH`'s own row shape)
  unfiltered, unordered -- every other `opts` field applies afterward,
  generically, not here.
  """
  @spec via_match_query([String.t()], {pos_integer(), pos_integer()}, boolean(), boolean()) ::
          String.t()
  def via_match_query(edge, {min_hops, max_hops}, backward?, shortest?)
      when is_list(edge) and is_integer(min_hops) and is_integer(max_hops) and
             is_boolean(backward?) and is_boolean(shortest?) do
    rel_type = edge |> Enum.join(".") |> quote_identifier()
    hop_range = "#{Integer.to_string(min_hops)}..#{Integer.to_string(max_hops)}"
    rel_pattern = "[:#{rel_type}*#{hop_range}]"
    {left, right} = if backward?, do: {"<-", "-"}, else: {"-", "->"}
    shortest_prefix = if shortest?, do: "SHORTEST 1 ", else: ""

    """
    MATCH (start) WHERE elementId(start) = $start_id
    MATCH p = #{shortest_prefix}(start)#{left}#{rel_pattern}#{right}(end)
    WHERE ALL(n IN nodes(p) WHERE size([x IN nodes(p) WHERE x = n]) = 1)
    RETURN end, nodes(p) AS path_nodes
    """
  end

  @doc """
  Builds the Cypher text fetching every node carrying `label` (a query's
  own top-level `source`), unfiltered -- `Scry.Core.QueryOps.run_flat/3`
  applies every ordinary `WHERE`/`GROUP BY`/`ORDER BY`/projection
  afterward, generically, the exact same "fetch the whole labeled set,
  let core's own pipeline do the rest" posture `scry_graph`'s reference
  `Executor` already has for its own top-level (non-`VIA`) path.
  """
  @spec fetch_label_query(String.t()) :: String.t()
  def fetch_label_query(label) when is_binary(label) do
    "MATCH (n:#{quote_identifier(label)}) RETURN n"
  end
end
