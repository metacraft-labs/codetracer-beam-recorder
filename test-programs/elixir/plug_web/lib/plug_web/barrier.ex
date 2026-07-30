defmodule PlugWeb.Barrier do
  @moduledoc """
  A rendezvous for the demo's `/concurrent/:slot` route.

  `arrive/1` blocks until `cohort_size` callers are waiting, then releases all
  of them.  That turns "these requests probably overlap" into "these requests
  cannot not overlap": every request in the cohort is inside its handler at
  the same instant, so the recorder must produce N spans whose step ranges
  interleave.

  Sizing the cohort to 1 makes `arrive/1` return immediately and the whole
  route becomes a plain 200 — which is how the integration test gets a
  strictly sequential schedule to compare against.
  """

  use GenServer

  @timeout 15_000

  def start_link(cohort_size) when is_integer(cohort_size) and cohort_size > 0 do
    GenServer.start_link(__MODULE__, cohort_size, name: __MODULE__)
  end

  @doc "Block until the cohort is complete.  Returns `:ok`."
  def arrive(slot) do
    GenServer.call(__MODULE__, {:arrive, slot}, @timeout)
  end

  @impl true
  def init(cohort_size) do
    {:ok, %{cohort_size: cohort_size, waiting: []}}
  end

  @impl true
  def handle_call({:arrive, slot}, from, state) do
    waiting = [{from, slot} | state.waiting]

    if length(waiting) >= state.cohort_size do
      for {waiter, _slot} <- waiting, do: GenServer.reply(waiter, :ok)
      {:noreply, %{state | waiting: []}}
    else
      {:noreply, %{state | waiting: waiting}}
    end
  end
end
