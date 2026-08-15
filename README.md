# scry_engine_neo4j

A real [`Scry.Core.EngineBehaviour`](https://github.com/joetjen/scry_core)
implementation over [Neo4j](https://neo4j.com/), via
[`boltx`](https://hex.pm/packages/boltx). Replaces `scry_graph`'s own
reference implementation (`Scry.Graph.Executor` -- a naive recursive-DFS
path enumerator over an in-memory graph) with genuine `SHORTEST`/
variable-length-relationship-pattern execution against a real graph
database -- the graph kind's first real adapter, closing the one kind
with zero real-backend validation up to this point (time-series and
search have each been validated twice already: `scry_engine_
redistimeseries`/`scry_engine_redisearch`/`scry_engine_elasticsearch`).

Like `scry_search`/`scry_logic` (replaced by `scry_engine_redisearch`/
`scry_engine_elasticsearch`/`scry_engine_episteme`), `graph` has no
separate engine tier in its own reference form -- `Scry.Graph.Executor`
takes a bespoke `Scry.Graph.Conn.t()` directly, not an ordinary
`EngineBehaviour` callback, because `VIA` needs the *whole* graph, not
just the rows behind one already-resolved source. This package
implements `Scry.Core.EngineBehaviour` directly instead, translating
each `VIA` traversal into a real Cypher query rather than calling
`Scry.Graph.Executor` at all.

Source: <https://github.com/joetjen/scry_engine_neo4j>. The behaviour
this implements lives in
[`scry_core`](https://github.com/joetjen/scry_core).

## Usage

```elixir
{:ok, conn} = Scry.Engine.Neo4j.Conn.open(auth: [username: "neo4j", password: "..."])

{:ok, query} = Scry.Core.parse(~s(SELECT Person WHERE name = "Alice" { via knows { name } }))
{:ok, cursor} = Scry.Core.Executor.run(query, Scry.Engine.Neo4j, conn)
rows = Scry.Core.Cursor.to_list(cursor)
# rows == [%{"via" => [%{"name" => "Bob"}, %{"name" => "Dave"}]}]
```

Creating nodes/relationships is entirely the caller's own job -- this
package is schema-agnostic and issues nothing but ordinary Cypher
(never `CREATE`/`MERGE`/`DELETE` -- only read queries).

### Local development / running the test suite

```sh
docker run -d --name scry-neo4j -p 7687:7687 -e NEO4J_AUTH=neo4j/scrytest123 neo4j:5-community
```

## Driver: `boltx`, not `bolt_sips`

`bolt_sips` -- the originally planned driver -- is
confirmed stale: last Hex release April 2021, and its own README now
points to `boltx` as the maintained successor. `boltx` itself is pre-1.0
(last Hex release Feb 2024) and has a real, confirmed rough edge (see
"A real boltx bug" below), but its GitHub repo still has commits into
mid-2025, it's `DBConnection`-based, and its typed `Node`/`Relationship`/
`Path` structs (`.properties`/`.labels`/`.nodes`/`.relationships`) are a
clean fit -- the better of the two real options, not a default choice.

## Scope: what translates to Cypher, and what stays generic

**Only the traversal shape itself is ever compiled to Cypher.** Every one
of `VIA`'s own `WHERE`/`ORDER BY`/`DISTINCT`/`LIMIT`/`OFFSET`, and the
top-level query's own `WHERE`/`GROUP BY`/aggregates/`ORDER BY`/`LIMIT`/
`OFFSET`/projection, apply *generically* -- via `Scry.Core.QueryOps.
run_flat/3`, the exact same "reference engine's own predicate evaluator,
not a hand-rolled translator" posture `scry_graph`'s own reference
`Executor` already uses for the identical fields. This is a deliberate
simplification, not a missed optimization: it sidesteps the whole "does
Cypher's own `NULL` handling for a schemaless node's missing property
match Scry's own semantics" question entirely (the same question
`scry_engine_elasticsearch`/`scry_engine_redisearch` answered by
declining pushdown for a schemaless store) by never pushing those
constructs down in the first place -- correctness by construction, at
the cost of fetching every `VIA` candidate before filtering rather than
letting Neo4j's own query planner narrow it first (a real, stated
performance tradeoff, the same "not optimized for large/dense graphs"
scale `scry_graph`'s own reference `Conn` already states for itself).

`VIA`/`PATH`/nested-`SELECT` combined with `GROUP BY`, and a `PATH` body
item reached outside any enclosing `VIA`, decline exactly like the
reference (`{:unsupported, :via_with_group_by}`/`{:unsupported,
:path_outside_via}`). Nested `VIA` (a `VIA` inside another `VIA`'s own
inner body) and more than one `VIA` in the same body (`"via"` if it's
the only one, `"via_1"`/`"via_2"`/... otherwise) both fall out of this
module's own recursive structure for free.

`%Scry.Core.CombinedQuery{}` and a `WITH`-bound top-level `source` both
delegate to `Scry.Core.QueryOps.run_document/4` rather than declining
outright the way the reference does -- `scry_graph`'s own `Scry.Graph.
Executor` never had the option (it isn't registered as an
`EngineBehaviour` implementation at all), but this package is.

A source label that matches no node at all is simply an empty result,
not an error -- confirmed directly: `MATCH (n:NoSuchLabel) RETURN n`
against a real container returns zero rows, no error of any kind. This
is a real, deliberate divergence from `scry_graph`'s own reference
`fetch_source/2` (which errors for a source absent from its own
synthetic `nodes` map).

## Two real findings from building this, not assumed

- **Cypher's variable-length relationship pattern does not enforce
  simple-path semantics by default.** `-[:KNOWS*1..6]->` happily
  revisits an already-visited *node* within the same path (only
  relationship reuse is disallowed) -- a real, confirmed divergence
  from `scry_graph`'s own reference `enumerate_paths/5` (a genuine
  simple-path DFS). Left unfixed, a graph containing any cycle at all
  would silently return paths the reference implementation could never
  produce. Fixed with a standard, plugin-free Cypher idiom -- `WHERE
  ALL(n IN nodes(p) WHERE size([x IN nodes(p) WHERE x = n]) = 1)` --
  confirmed, against a real cyclic graph, to restore simple-path
  semantics exactly and to compose cleanly with `SHORTEST 1`.
- **A `boltx` 0.0.6 connection-process crash on certain `FAILURE`
  responses is real, not hypothetical.** Confirmed directly: an
  unsupported `CYPHER 25` version prefix returns a clean `{:error, _}`
  the *first* time, but leaves the connection's own protocol state such
  that the *next* query on that same `pid` raises `DBConnection.
  ConnectionError` (a `CaseClauseError` inside `boltx` itself, on the
  Bolt protocol's own "previous message failed, ignoring until reset"
  signal, which `boltx` 0.0.6 doesn't handle). `Scry.Engine.Neo4j.Conn.
  query/3` wraps every call in `rescue` and normalizes this to an
  ordinary `{:error, {:query_error, reason}}` -- `boltx`'s own
  `DBConnection` pool respawns the crashed connection process
  automatically for the next checkout, so this costs one failed query,
  not a dead connection.

## One stated, deliberate divergence: `SHORTEST` and tied paths

Neo4j's modern `SHORTEST 1` clause (no `CYPHER 25` version prefix
needed -- confirmed this server only accepts Cypher version `5`, its own
calendar-versioned default) returns exactly **one** shortest path per
reachable end node. `scry_graph`'s own reference `keep_shortest/1` keeps
*every* path tied for minimum length to the same end node. Neo4j 5.26
community's own GQL grammar has no plugin-free equivalent to "all ties"
confirmed safe to use here (the one syntax candidate found, `SHORTEST 1
GROUPS`, triggered the `boltx` connection-crash bug above before it
could be verified, and re-triggering that bug class for an edge-case
tie-break wasn't worth it) -- a real, stated scope limit, not silently
different behavior. `test/scry/engine/neo4j/parity_test.exs` documents
and asserts around this exact divergence directly.

## Parity testing against the reference

AGENTS.md's "Parity between multiple implementations" rule applies
directly here: `scry_graph`'s reference `Executor` and this package are
two implementations of the identical `VIA`/`PATH` semantics.
`test/scry/engine/neo4j/parity_test.exs` parses one query text once
(`Scry.Graph.parse/1`) and runs the exact same `%Scry.Core.Query{}`
against a byte-for-byte identical fixture graph in both a real Neo4j
container and the reference's own in-memory `Conn`, asserting the
projected values agree (`scry_graph` is a `only: :test` dependency for
exactly this purpose).

## Installation

```elixir
def deps do
  [
    {:scry_engine_neo4j, "~> 0.1.0"}
  ]
end
```

## Documentation

Documentation is generated with [ExDoc](https://github.com/elixir-lang/ex_doc):

- Released versions are published to [HexDocs](https://hexdocs.pm) once the
  package ships, at <https://hexdocs.pm/scry_engine_neo4j>.
