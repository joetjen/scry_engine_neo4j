defmodule Scry.Engine.Neo4j do
  @moduledoc """
  A real `Scry.Core.EngineBehaviour` implementation over Neo4j, via
  [`boltx`](https://hex.pm/packages/boltx) (`Scry.Engine.Neo4j.Conn`'s
  own moduledoc has the driver choice, and a real, confirmed rough edge
  worked around there). Replaces `scry_graph`'s own reference
  implementation (`Scry.Graph.Executor` -- a naive recursive-DFS path
  enumerator over an in-memory `nodes`/`edges` map) with genuine
  `SHORTEST`/variable-length-relationship-pattern execution against a
  real graph database -- the graph kind's first real adapter, closing
  the one kind with zero real-backend validation up to this point
  (time-series and search have each been validated twice: `scry_engine_
  redistimeseries`/`scry_engine_prometheus`-to-come, and `scry_engine_
  elasticsearch`/`scry_engine_redisearch`).

  Like `scry_search`/`scry_logic` (replaced by `scry_engine_redisearch`/
  `scry_engine_elasticsearch`/`scry_engine_episteme`), `graph` has no
  separate engine tier in its own reference form -- `Scry.Graph.Executor`
  takes a bespoke `Scry.Graph.Conn.t()` directly, not an ordinary
  `EngineBehaviour` callback, because `VIA` needs the *whole* graph
  (every node, the full edge index), not just the rows behind one
  already-resolved source (that module's own moduledoc has the full
  "why this can't be a pure AST-rewrite-then-delegate pass" story). This
  package implements `Scry.Core.EngineBehaviour` directly instead,
  translating each `VIA` traversal into a real Cypher query rather than
  calling `Scry.Graph.Executor` at all.

  ## Scope: what translates to Cypher, and what stays generic

  **Only the traversal shape itself is ever compiled to Cypher** --
  `Scry.Engine.Neo4j.Cypher.via_match_query/4`'s own moduledoc has the
  two real findings from confirming this against a real container (no
  simple-path guarantee by default in Cypher's own variable-length
  patterns; `SHORTEST 1`'s own "one path per end node, not every tie"
  scope note). Every one of `VIA`'s own `WHERE`/`ORDER BY`/`DISTINCT`/
  `LIMIT`/`OFFSET`, and the top-level query's own `WHERE`/`GROUP BY`/
  aggregates/`ORDER BY`/`LIMIT`/`OFFSET`/projection, apply *generically*
  -- via `Scry.Core.QueryOps.run_flat/3`, exactly the same "reference
  engine's own predicate evaluator, not a hand-rolled translator"
  posture `scry_graph`'s own reference `Executor` already uses for the
  identical fields (`filter_and_order_paths/4`/`order_and_limit/3`
  there). This is a deliberate simplification, not a missed
  optimization: it sidesteps the whole "does Cypher's own `NULL`
  handling for a schemaless node's missing property match Scry's own
  semantics" question entirely (the same question `scry_engine_
  elasticsearch`/`scry_engine_redisearch` answered by declining
  pushdown for a schemaless store) by never pushing those constructs
  down in the first place -- correctness by construction, reusing code
  every sibling adapter and the reference itself already trust, at the
  cost of fetching every `VIA` candidate before filtering rather than
  letting Neo4j's own query planner narrow it first (a real, stated
  performance tradeoff, the same "not optimized for large/dense graphs"
  scale `scry_graph`'s own reference `Conn` already states for itself).

  `VIA`/`PATH`/nested-`SELECT` combined with `GROUP BY`, and a `PATH`
  body item reached outside any enclosing `VIA`, decline exactly like
  the reference (`{:unsupported, :via_with_group_by}`/`{:unsupported,
  :path_outside_via}`) -- an aggregated row no longer corresponds to one
  specific node, and a bare `PATH` has nothing to mean outside a
  traversal. Nested `VIA` (a `VIA` inside another `VIA`'s own inner
  body) and more than one `VIA` in the same body (`"via"` if it's the
  only one, `"via_1"`/`"via_2"`/... otherwise, matching the reference's
  own numbering) both fall out of this module's own recursive structure
  for free -- neither needed a separate scope decision, unlike a first
  pass through this design assumed.

  `%Scry.Core.CombinedQuery{}` and a `WITH`-bound top-level `source`
  both delegate to `Scry.Core.QueryOps.run_document/4` (recursing back
  into this module's own `execute/3` for every flat leaf) rather than
  declining outright the way the reference does -- `scry_graph`'s own
  `Scry.Graph.Executor` never had the option (it isn't registered as an
  `EngineBehaviour` implementation at all), but this package is, so the
  same "an engine that hasn't implemented a construct doesn't have to
  reimplement `run_document/4`'s own generic resolution" posture
  `scry_engine_redisearch`/every other real adapter in this family
  already takes applies here too.

  A source label that matches no node at all is simply an empty result,
  not an error -- confirmed directly: `MATCH (n:NoSuchLabel) RETURN n`
  against a real container returns zero rows, no error of any kind.
  This is a real, deliberate divergence from `scry_graph`'s own
  reference `fetch_source/2` (which returns `{:error, {:query_error,
  {:no_such_source, source}}}` for a source absent from its own
  synthetic `nodes` map) -- a real backend's own "label matches
  nothing" is honestly just an empty answer, not a broken query, unlike
  a reference implementation's in-memory map having no such key at all.
  """

  @behaviour Scry.Core.EngineBehaviour

  alias Scry.Core.{CombinedQuery, EngineBehaviour, Query, QueryOps}
  alias Scry.Engine.Neo4j.{Conn, Cypher}

  @row_marker_field "__scry_neo4j_row__"
  @path_marker_field "__scry_neo4j_path__"

  @impl true
  def execute(conn, %CombinedQuery{} = combined, params),
    do: QueryOps.run_document(conn, combined, params, __MODULE__)

  def execute(%Conn{} = conn, %Query{} = query, params) do
    if with_bound_source?(query) do
      QueryOps.run_document(conn, query, params, __MODULE__)
    else
      run(conn, query, params)
    end
  end

  defp with_bound_source?(%Query{source: [name], with_bindings: with_bindings}),
    do: Map.has_key?(with_bindings, name)

  defp with_bound_source?(_query), do: false

  defp run(conn, %Query{source: source} = query, params) do
    label = List.last(source)

    with {:ok, nodes} <- fetch_label(conn, label) do
      if special_items?(query.select) do
        run_with_special_items(conn, query, nodes, params)
      else
        run_flat_over_nodes(nodes, query, params)
      end
    end
  end

  # Neither `VIA`/`PATH` nor a nested `SELECT` anywhere in this query's
  # own top-level select -- nothing graph-specific to do. Delegating
  # wholesale, unmodified query included, is the correctness-critical
  # path here (mirroring `scry_graph`'s own reference `run/3`, same
  # reasoning): `GROUP BY`/aggregation only works correctly when
  # `run_flat/3` sees every row belonging to a group *at once*, which
  # the per-row marker technique `run_with_special_items/4` needs would
  # never give it.
  defp run_flat_over_nodes(nodes, query, params) do
    rows = Enum.map(nodes, & &1.properties)
    QueryOps.run_flat(rows, query, params)
  end

  defp fetch_label(conn, label) do
    with {:ok, response} <- Conn.query(conn, Cypher.fetch_label_query(label)) do
      {:ok, Enum.map(response.results, fn %{"n" => node} -> node end)}
    end
  end

  defp special_items?(body_items) do
    Enum.any?(body_items, fn
      {:variant, {:via, _edge, _opts, _body}} -> true
      {:variant, :path} -> true
      %Query{} -> true
      _other -> false
    end)
  end

  defp run_with_special_items(conn, query, nodes, params) do
    with :ok <- validate_no_grouping(query),
         {:ok, ordered_nodes} <- order_and_limit(nodes, query, params) do
      own_name = List.last(query.source)

      case project_all(ordered_nodes, query.select, conn, own_name, params) do
        {:ok, projected} -> {:ok, projected}
        {:error, _reason} = error -> error
      end
    end
  end

  defp validate_no_grouping(%Query{group_bys: []}), do: :ok
  defp validate_no_grouping(_query), do: {:error, {:unsupported, :via_with_group_by}}

  # Threads a unique, synthetic per-row index through `run_flat/3` (not
  # any real property -- two distinct nodes can have identical
  # properties, and this module must never stomp a node's own real
  # `"id"`-or-otherwise-named property) so the post-filter/order/limit
  # survivor list can be mapped back to its own original `Boltx.Types.
  # Node` -- element_id included, needed for any `VIA` reached from
  # project_body/6 below. Mirrors `scry_graph`'s reference `Executor`'s
  # own identical technique (`order_and_limit/3` there).
  defp order_and_limit(nodes, query, params) do
    indexed = Enum.with_index(nodes)
    lookup = Map.new(indexed, fn {node, idx} -> {idx, node} end)

    tagged_rows =
      Enum.map(indexed, fn {node, idx} -> Map.put(node.properties, @row_marker_field, idx) end)

    marker_query = %{query | select: [{:field, [@row_marker_field]}]}

    with {:ok, marker_rows} <- QueryOps.run_flat(tagged_rows, marker_query, params) do
      ordered =
        marker_rows
        |> Enum.to_list()
        |> Enum.map(fn %{@row_marker_field => idx} -> Map.fetch!(lookup, idx) end)

      {:ok, ordered}
    end
  end

  defp project_all(nodes, select, conn, own_name, params) do
    nodes
    |> Enum.map(fn node -> project_body(node, select, conn, nil, own_name, params) end)
    |> Enum.split_with(&match?({:error, _}, &1))
    |> case do
      {[], oks} -> {:ok, Enum.map(oks, fn {:ok, row} -> row end)}
      {[first_error | _], _rows} -> first_error
    end
  end

  # Projects one node against `body` -- plain fields delegate to `Scry.
  # Core.QueryOps.run_flat/3` (this package contributes no ordinary
  # body-item evaluation of its own), a nested `%Scry.Core.Query{}` body
  # item resolves via `Scry.Core.QueryOps.resolve_correlated_nested/5`,
  # `VIA` items resolve recursively through this same function (one hop
  # relative to `node`), and a bare `PATH` resolves against `path_rows`
  # (the enclosing `VIA`'s own accumulated path, or an error if there is
  # none). `own_name` is always the *original, top-level* query's own
  # source name, unchanged as this recurses into a `VIA`'s own inner
  # body -- correlating a nested `SELECT` inside a `VIA` body to
  # anything other than the top-level source is a real, stated scope
  # limit, the identical one `scry_graph`'s own reference `Executor`
  # already states (that module's own moduledoc has the full reasoning).
  defp project_body(node, body, conn, path_rows, own_name, params) do
    {ordinary, has_path?, via_items} = partition_body(body)
    {nested_items, flat_select} = Enum.split_with(ordinary, &is_struct(&1, Query))

    with {:ok, base} <- project_ordinary(node.properties, flat_select, params),
         {:ok, with_nested} <-
           add_nested_results(base, nested_items, node.properties, conn, own_name, params),
         {:ok, with_path} <- add_path(with_nested, has_path?, path_rows) do
      add_via_results(with_path, via_items, node, conn, own_name, params)
    end
  end

  defp partition_body(body_items) do
    Enum.reduce(body_items, {[], false, []}, fn
      {:variant, :path}, {ord, _has_path, vias} ->
        {ord, true, vias}

      {:variant, {:via, edge, opts, inner}}, {ord, has_path, vias} ->
        {ord, has_path, vias ++ [{edge, opts, inner}]}

      item, {ord, has_path, vias} ->
        {ord ++ [item], has_path, vias}
    end)
  end

  defp add_nested_results(base, [], _properties, _conn, _own_name, _params), do: {:ok, base}

  defp add_nested_results(base, nested_items, properties, conn, own_name, params) do
    Enum.reduce_while(nested_items, {:ok, base}, fn nested, {:ok, acc} ->
      resolve_nested(nested, acc, properties, conn, own_name, params)
    end)
  end

  defp resolve_nested(nested, acc, properties, conn, own_name, params) do
    fetch_fn = fn q, p -> fetch_and_drain(conn, q, p) end

    case QueryOps.resolve_correlated_nested(nested, properties, own_name, params, fetch_fn) do
      {:ok, rows} -> {:cont, {:ok, Map.put(acc, List.last(nested.source), rows)}}
      {:error, _} = err -> {:halt, err}
    end
  end

  defp fetch_and_drain(conn, query, params) do
    with {:ok, enumerable} <- execute(conn, query, params) do
      {:ok, Enum.to_list(enumerable)}
    end
  end

  defp add_path(base, false, _path_rows), do: {:ok, base}
  defp add_path(_base, true, nil), do: {:error, {:unsupported, :path_outside_via}}
  defp add_path(base, true, path_rows), do: {:ok, Map.put(base, "path", path_rows)}

  defp add_via_results(base, [], _node, _conn, _own_name, _params), do: {:ok, base}

  defp add_via_results(base, [{edge, opts, inner}], node, conn, own_name, params) do
    with {:ok, results} <- resolve_via(node, edge, opts, inner, conn, own_name, params) do
      {:ok, Map.put(base, "via", results)}
    end
  end

  defp add_via_results(base, via_items, node, conn, own_name, params) do
    via_items
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, base}, fn {{edge, opts, inner}, idx}, {:ok, acc} ->
      case resolve_via(node, edge, opts, inner, conn, own_name, params) do
        {:ok, results} -> {:cont, {:ok, Map.put(acc, "via_#{idx}", results)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp project_ordinary(_properties, [], _params), do: {:ok, %{}}

  defp project_ordinary(properties, select, params) do
    case QueryOps.run_flat([properties], %Query{select: select}, params) do
      {:ok, enumerable} ->
        case Enum.to_list(enumerable) do
          [projected] -> {:ok, projected}
          [] -> {:ok, %{}}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp resolve_via(node, edge, opts, inner_body, conn, own_name, params) do
    hops = opts.hops || {1, 1}
    cypher = Cypher.via_match_query(edge, hops, opts.backward, opts.shortest)

    with {:ok, response} <- Conn.query(conn, cypher, %{"start_id" => node.element_id}) do
      response
      |> decode_candidates()
      |> project_and_finalize(opts, inner_body, conn, own_name, params)
    end
  end

  defp decode_candidates(response) do
    Enum.map(response.results, fn %{"end" => end_node, "path_nodes" => path_nodes} ->
      {end_node, Enum.map(path_nodes, & &1.properties)}
    end)
  end

  defp project_and_finalize(candidates, opts, inner_body, conn, own_name, params) do
    with {:ok, ordered_candidates} <- filter_and_order_candidates(candidates, opts, params) do
      ordered_candidates
      |> Enum.map(fn {end_node, path_rows} ->
        project_body(end_node, inner_body, conn, path_rows, own_name, params)
      end)
      |> finalize_via_rows(opts)
    end
  end

  defp finalize_via_rows(projected, opts) do
    case Enum.split_with(projected, &match?({:error, _}, &1)) do
      {[], oks} ->
        rows = Enum.map(oks, fn {:ok, r} -> r end)
        rows = if opts.distinct, do: Enum.uniq(rows), else: rows
        rows = rows |> maybe_drop(opts.offset) |> maybe_take(opts.limit)
        {:ok, rows}

      {[first_error | _], _rows} ->
        first_error
    end
  end

  # `WHERE`/`ORDER BY` only, generic via `run_flat/3` against each
  # candidate end node's own raw properties (this module's own
  # moduledoc has the full "why not translated to Cypher" reasoning).
  # `DISTINCT`/`LIMIT`/`OFFSET` deliberately apply afterward, to the
  # *final projected* rows -- mirrors `scry_graph`'s reference
  # `filter_and_order_paths/4`, same synthetic-marker technique.
  defp filter_and_order_candidates(candidates, opts, params) do
    indexed = Enum.with_index(candidates)
    lookup = Map.new(indexed, fn {candidate, idx} -> {idx, candidate} end)

    tagged_rows =
      Enum.map(indexed, fn {{end_node, _path_rows}, idx} ->
        Map.put(end_node.properties, @path_marker_field, idx)
      end)

    query = %Query{
      wheres: if(opts.where, do: [opts.where], else: []),
      order_bys: opts.order_bys,
      select: [{:field, [@path_marker_field]}]
    }

    with {:ok, enumerable} <- QueryOps.run_flat(tagged_rows, query, params) do
      ordered =
        enumerable
        |> Enum.to_list()
        |> Enum.map(fn %{@path_marker_field => idx} -> Map.fetch!(lookup, idx) end)

      {:ok, ordered}
    end
  end

  defp maybe_drop(rows, nil), do: rows
  defp maybe_drop(rows, n), do: Enum.drop(rows, n)

  defp maybe_take(rows, nil), do: rows
  defp maybe_take(rows, n), do: Enum.take(rows, n)

  @doc """
  `Scry.Core.EngineBehaviour`'s optional `describe_source/2` callback --
  converts `source`'s own real `CALL db.schema.nodeTypeProperties()`
  rows (confirmed directly: `nodeType`/`nodeLabels`/`propertyName`/
  `propertyTypes`/`mandatory`, `mandatory` reflecting what was *observed*
  across sampled nodes, not a real, enforced constraint -- Neo4j
  Community has no property-existence-constraint feature at all) into
  `introspected_field()`s, filtered to `source`'s own label.
  `mandatory: true` maps to `nullable: false` as a best-effort, sample-
  based signal only -- never something `execute/3`'s own contract relies
  on for pushdown safety (this module's own moduledoc has the full
  "why nothing is pushed down on that basis" reasoning); a later node
  genuinely missing that property wouldn't be a contradiction, just a
  stale observation.
  """
  @impl true
  @spec describe_source(Conn.t(), String.t()) ::
          {:ok, [EngineBehaviour.introspected_field()]}
          | {:error, :not_found}
          | {:error, {:introspection_error, term()}}
  def describe_source(%Conn{} = conn, source) do
    case Conn.query(conn, "CALL db.schema.nodeTypeProperties()") do
      {:ok, response} ->
        fields =
          response.results
          |> Enum.filter(fn %{"nodeLabels" => labels} -> source in labels end)
          |> Enum.map(&introspected_field/1)

        if fields == [] do
          {:error, :not_found}
        else
          {:ok, fields}
        end

      {:error, {:query_error, reason}} ->
        {:error, {:introspection_error, reason}}
    end
  end

  defp introspected_field(%{"propertyName" => name, "propertyTypes" => types, "mandatory" => m}) do
    %{name: name, nullable: not m, scalar: introspected_scalar(types)}
  end

  defp introspected_scalar(["String"]), do: :string
  defp introspected_scalar(["Boolean"]), do: :boolean
  defp introspected_scalar(["Long"]), do: :integer
  defp introspected_scalar(["Double"]), do: :float
  defp introspected_scalar(_other), do: :unknown
end
