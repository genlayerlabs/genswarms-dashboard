defmodule GenswarmsDashboard.EventsSource do
  @moduledoc "Cursor-read of the host's display event feed. Implemented by the host app."

  @doc """
  Events with seq > since, oldest first, plus the cursor to poll from next.

  PINNED cursor semantics: `seq` is ALWAYS the feed's current cursor — the
  highest seq the feed has assigned (0 if none) — NEVER an echo of `since`.
  This is what makes restart detection possible: seqs are gapless per feed
  instance, so a gap observed by a consumer means ring pruning (resync), and a
  returned `seq` BELOW the consumer's cursor means the feed restarted
  (re-baseline). An echo-on-empty implementation would leave a consumer polling
  a dead cursor forever after a host restart.
  """
  @callback events_since(since :: non_neg_integer(), limit :: pos_integer()) ::
              %{events: [map()], seq: non_neg_integer()} | :unavailable
end
