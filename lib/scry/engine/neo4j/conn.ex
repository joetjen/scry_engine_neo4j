defmodule Scry.Engine.Neo4j.Conn do
  @moduledoc """
  Wraps a `boltx` connection pid -- opened once via `open/1` and meant
  to be reused across many `Scry.Engine.Neo4j.execute/3` calls, matching
  the connection/config struct every real adapter exposes. `boltx` is
  DBConnection-based (`Boltx.start_link/1`), the same
  supervised-reconnecting-process shape `redix`/`myxql`/`postgrex`
  already have -- unlike those, though, `query/3` here always wraps the
  real call in a `try`/`rescue`.

  **Why the rescue is load-bearing, not defensive boilerplate**:
  confirmed directly against a real `neo4j:5-community` container, not
  assumed -- a Neo4j `FAILURE` response to certain constructs (a real
  one found: an unsupported `CYPHER 25` version prefix) leaves the next
  message on that same connection unhandled by `boltx` 0.0.6 (a
  `CaseClauseError` on `{:ignored, [0, 0]}`, the Bolt protocol's own
  "previous message failed, ignoring until reset" signal), which crashes
  the whole underlying `gen_statem` connection process -- surfacing to
  the caller not as `{:error, _}` but as a raised
  `DBConnection.ConnectionError`. `query/3` catches exactly that and
  normalizes it to `{:error, {:query_error, reason}}`, the same shape an
  ordinary `{:error, %Boltx.Error{}}` reply already gets -- `Scry.Core.
  EngineBehaviour`'s own contract has no notion of a raised exception, so
  every driver-level failure mode has to funnel into its two-tuple error
  shape one way or another. `boltx`'s own `DBConnection` pool respawns
  the crashed connection process automatically for the *next* checkout
  (the entire point of `DBConnection` supervision), so this failure mode
  costs one failed query, not the whole connection going permanently
  dead -- confirmed by running a follow-up query on the same `pid`
  immediately after and getting a clean, correct reply back.
  """

  @type t :: %__MODULE__{pid: pid()}

  defstruct pid: nil

  @default_opts [hostname: "localhost", port: 7687, scheme: "bolt"]

  @doc """
  Starts a `boltx` connection against `opts` (`Boltx.start_link/1`'s own
  options), merged over this module's own explicit local-Docker defaults
  (`hostname: "localhost", port: 7687, scheme: "bolt"`). `auth: [username:
  ..., password: ...]` has no local default -- every real Neo4j instance
  requires it, so a caller always supplies it explicitly.
  """
  @spec open(keyword()) :: {:ok, t()} | {:error, term()}
  def open(opts \\ []) do
    with {:ok, pid} <- Boltx.start_link(Keyword.merge(@default_opts, opts)) do
      {:ok, %__MODULE__{pid: pid}}
    end
  end

  @doc "Stops the wrapped connection."
  @spec close(t()) :: :ok
  def close(%__MODULE__{pid: pid}), do: GenServer.stop(pid)

  @doc """
  Runs `cypher` with `params` against `conn`, normalizing every failure
  mode -- an ordinary `{:error, %Boltx.Error{}}` reply, or a raised
  `DBConnection.ConnectionError`/`DBConnection.EncodeError` (this
  module's own moduledoc has the full "why a raise is a real, confirmed
  outcome here" story) -- into `{:error, {:query_error, reason}}`, the
  one shape every caller in this package ever has to handle.
  """
  @spec query(t(), String.t(), map()) ::
          {:ok, Boltx.Response.t()} | {:error, {:query_error, term()}}
  def query(%__MODULE__{pid: pid}, cypher, params \\ %{}) when is_binary(cypher) do
    case Boltx.query(pid, cypher, params) do
      {:ok, %Boltx.Response{} = response} -> {:ok, response}
      {:error, reason} -> {:error, {:query_error, reason}}
    end
  rescue
    e -> {:error, {:query_error, Exception.message(e)}}
  end
end
