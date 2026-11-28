defmodule ExAthena.Web.TraceComponents do
  @moduledoc """
  The Trace tab's drawing: one SVG row per lane, a row of the notes the
  runtime sent, and two rows of tokens, over a shared time axis
  (issue 352). Data comes from `ExAthena.Web.Trace.build/2`, whose positions
  are already shares of the width, so each row is an SVG whose shapes take
  percentages and nothing here does arithmetic on time.

  `interactive` picks how a mark opens its details: `:live` sends the
  `trace_select` event to the LiveView, `:static` leaves a `data-mark` for the
  small script of a saved file (`mix athena.trace`), which renders every
  turn's details up front.
  """
  use Phoenix.Component

  alias ExAthena.Web.Trace

  # A tool's output past this many characters is cut, on screen and in a
  # saved file alike.
  @max_output_chars 2_000
  @max_thinking_chars 600
  @max_args_chars 400

  @doc false
  def max_output_chars, do: @max_output_chars

  @kind_labels %{
    error: "error",
    test_failed: "test failed",
    test_passed: "test passed",
    edit: "edit",
    command: "command",
    helper: "helper sent",
    question: "question",
    lookup: "library lookup",
    read: "read/search",
    answer: "answer"
  }

  @note_labels [
    {"R", "research note"},
    {"L", "repeat note"},
    {"W", "wrap-up note"},
    {"H", "handback"},
    {"O", "open steps"},
    {"V", "verification check"},
    {"T", "test check"},
    {"C", "coverage check"},
    {"A", "audit check"},
    {"Z", "history compacted"}
  ]

  attr :trace, :map, required: true
  attr :selected, :string, default: nil
  attr :interactive, :atom, default: :live, values: [:live, :static]

  def trace_panel(assigns) do
    assigns =
      assign(assigns,
        selected_mark: find_mark(assigns.trace, assigns.selected),
        kind_labels: @kind_labels,
        note_labels: @note_labels
      )

    ~H"""
    <div class="trace" id="trace">
      <div class="trace-header" id="trace-header">
        <span class="trace-title">Trace</span>
        <span :if={@trace.id}>· {@trace.id}</span>
        <span :if={@trace.timed?}>· {Trace.duration(@trace.duration_ms)}</span>
        <span>· {@trace.turn_count} turns</span>
        <span>· {Trace.compact(@trace.tokens_in)} tokens in</span>
        <button
          :if={@interactive == :live and @trace.turn_count > 0}
          class="trace-save"
          id="trace-save"
          phx-click="trace_save"
          title="Save this trace as one HTML file"
        >Save</button>
      </div>

      <div :if={not @trace.timed? and @trace.turn_count > 0} class="trace-notice" id="trace-untimed">
        This session was saved without times, so its turns are evenly spaced.
      </div>

      <%= if @trace.turn_count == 0 and @trace.requests == [] do %>
        <div class="details-empty" id="trace-empty">
          <div class="details-empty-title">Trace</div>
          <div class="details-empty-sub">Send a message: each turn of the run will draw here.</div>
        </div>
      <% else %>
        <div class="trace-rows">
          <div class="trace-row trace-row--axis">
            <div class="trace-label"></div>
            <svg class="trace-svg trace-svg--axis" height="16" width="100%">
              <text
                :for={t <- @trace.ticks}
                x={"#{t.x}%"}
                y="12"
                text-anchor={anchor(t.x)}
                class="trace-tick"
              >{t.label}</text>
            </svg>
          </div>

          <div class="trace-row" id="trace-lane-you">
            <div class="trace-label">you</div>
            <svg class="trace-svg" height="18" width="100%">
              <g :for={r <- @trace.requests}>
                <title>{Trace.excerpt(r.text, 200)}</title>
                <text x={"#{r.x}%"} y="13" text-anchor={anchor(r.x)} class="trace-request">▲</text>
              </g>
            </svg>
          </div>

          <div :for={lane <- @trace.lanes} class="trace-row" id={"trace-lane-#{lane.id}"} data-lane={lane.kind}>
            <div class="trace-label" title={lane.title}>{lane.label}</div>
            <svg class="trace-svg" height="18" width="100%">
              <rect
                :if={lane.span}
                class="trace-span"
                x={"#{elem(lane.span, 0)}%"}
                width={"#{max(elem(lane.span, 1) - elem(lane.span, 0), 0.3)}%"}
                y="8"
                height="2"
              />
              <rect
                :for={m <- lane.marks}
                id={"trace-mark-#{m.id}"}
                class={["trace-mark", "trace-mark--#{m.kind}", @selected_mark && @selected_mark.id == m.id && "is-selected"]}
                data-kind={m.kind}
                data-mark={m.id}
                phx-click={@interactive == :live && "trace_select"}
                phx-value-mark={@interactive == :live && m.id}
                x={"#{m.x}%"}
                width={"#{max(m.w, 0.4)}%"}
                y="3"
                height="12"
              ><title>{mark_title(@trace, m)}</title></rect>
            </svg>
          </div>

          <div class="trace-row" id="trace-notes">
            <div class="trace-label">notes</div>
            <svg class="trace-svg" height="18" width="100%">
              <g :for={n <- @trace.notes} class="trace-note" data-note={n.letter} data-turn={n.turn}>
                <title>{Trace.excerpt(n.text, 300)}</title>
                <text
                  x={"#{n.x}%"}
                  y="13"
                  text-anchor={anchor(n.x)}
                  class={["trace-note-letter", "trace-note--#{n.kind}"]}
                  data-mark={n.turn}
                  phx-click={@interactive == :live && "trace_select"}
                  phx-value-mark={@interactive == :live && n.turn}
                >{n.letter}</text>
              </g>
            </svg>
          </div>

          <div class="trace-row">
            <div class="trace-label">tokens in</div>
            <svg class="trace-svg" height="24" width="100%">
              <rect
                :for={{p, w} <- token_bars(@trace.tokens)}
                class="trace-tokens-in"
                x={"#{p.x}%"}
                width={"#{w}%"}
                y={"#{100 - p.h_in}%"}
                height={"#{p.h_in}%"}
              ><title>{p.input} in</title></rect>
            </svg>
          </div>

          <div class="trace-row">
            <div class="trace-label">cached</div>
            <svg class="trace-svg" height="24" width="100%">
              <rect
                :for={{p, w} <- token_bars(@trace.tokens)}
                class="trace-tokens-cached"
                x={"#{p.x}%"}
                width={"#{w}%"}
                y={"#{100 - p.h_cached}%"}
                height={"#{p.h_cached}%"}
              ><title>{p.cached} cached</title></rect>
            </svg>
          </div>
        </div>

        <div class="trace-legend">
          <span :for={k <- Trace.kinds()} class="trace-legend-item">
            <span class={["trace-swatch", "trace-mark--#{k}"]}></span>{@kind_labels[k]}
          </span>
          <span :for={{letter, label} <- @note_labels} class="trace-legend-item">
            <b>{letter}</b> {label}
          </span>
        </div>

        <%= if @interactive == :live do %>
          <.mark_details :if={@selected_mark} trace={@trace} mark={@selected_mark} />
          <div :if={is_nil(@selected_mark)} class="trace-hint">Click a mark to see that turn.</div>
        <% else %>
          <.mark_details :for={m <- all_marks(@trace)} trace={@trace} mark={m} hidden />
        <% end %>
      <% end %>
    </div>
    """
  end

  attr :trace, :map, required: true
  attr :mark, :map, required: true
  attr :hidden, :boolean, default: false

  defp mark_details(assigns) do
    assigns = assign(assigns, :turns, Enum.map(assigns.mark.turns, &assigns.trace.turns[&1]))

    ~H"""
    <div
      class="trace-details"
      id={"trace-detail-#{@mark.id}"}
      data-turns={Enum.join(@mark.turns, " ")}
      hidden={@hidden}
    >
      <div :for={turn <- @turns} class="trace-turn" id={"trace-turn-#{turn.id}"}>
        <div class="trace-turn-head">
          <span class={["trace-swatch", "trace-mark--#{turn.kind}"]}></span>
          {lane_name(@trace, turn.lane)} · turn {turn.n}
          <span :if={is_integer(turn.at) and @trace.timed?}>· at {Trace.duration(turn.at - @trace.x0)}</span>
          <span :if={turn.model_ms > 0}>· model {Trace.duration_precise(turn.model_ms)}</span>
          <span :if={turn.input > 0}>· {Trace.compact(turn.input)} in ({Trace.compact(turn.cached)} cached)</span>
        </div>

        <div :for={s <- turn.steers} class="trace-turn-steer">
          <div class="trace-turn-label">note sent · {steer_name(s)}</div>
          <pre class="detail-pre">{s.text}</pre>
        </div>

        <div :if={turn.errors != []} class="trace-turn-error">
          <pre :for={e <- turn.errors} class="detail-pre">{e}</pre>
        </div>

        <div :if={turn.thinking != ""} class="trace-turn-thinking">
          <div class="trace-turn-label">thinking</div>
          <pre class="detail-pre">{thinking_excerpt(turn.thinking)}</pre>
        </div>

        <div :for={c <- turn.calls} class="trace-call" data-tool={c.name}>
          <div class="trace-turn-label">
            {c.name}
            <span :if={c.test == :failed} class="trace-test trace-test--failed">test failed</span>
            <span :if={c.test == :passed} class="trace-test trace-test--passed">test passed</span>
            <span :if={c.test == :unconfirmed} class="trace-test">test result not shown</span>
            <span :if={c.is_error} class="trace-test trace-test--failed">error</span>
          </div>
          <pre class="detail-pre">{args_text(c.args)}</pre>
          <pre :if={c.result} class="detail-pre trace-call-result">{cut(c.result)}</pre>
        </div>

        <div :if={turn.text != ""} class="trace-turn-text">
          <div class="trace-turn-label">said</div>
          <pre class="detail-pre">{cut(turn.text)}</pre>
        </div>
      </div>
    </div>
    """
  end

  defp thinking_excerpt(text), do: Trace.excerpt(text, @max_thinking_chars)

  defp find_mark(_trace, nil), do: nil
  # A note names the turn it belongs to, which can sit inside a group mark.
  defp find_mark(trace, id), do: Enum.find(all_marks(trace), &(id in &1.turns))

  defp all_marks(trace), do: Enum.flat_map(trace.lanes, & &1.marks)

  defp mark_title(trace, %{turns: [one]}) do
    turn = trace.turns[one]
    "#{lane_name(trace, turn.lane)} turn #{turn.n} · #{@kind_labels[turn.kind]}"
  end

  defp mark_title(_trace, %{turns: turns, kind: kind}),
    do: "#{length(turns)} turns · #{@kind_labels[kind]}"

  defp lane_name(trace, lane_id) do
    case Enum.find(trace.lanes, &(&1.id == lane_id)) do
      nil -> lane_id
      lane -> lane.label
    end
  end

  defp steer_name(%{kind: :finish_check, check: check}), do: "#{check} check"
  defp steer_name(%{kind: kind}), do: kind |> to_string() |> String.replace("_", " ")

  # A label near the right edge would run off the drawing.
  defp anchor(x) when x > 92, do: "end"
  defp anchor(x) when x < 3, do: "start"
  defp anchor(_x), do: "middle"

  # Each bar runs to the next one, and the last is one share wide.
  defp token_bars([]), do: []

  defp token_bars(points) do
    xs = Enum.map(points, & &1.x)
    nexts = Enum.drop(xs, 1) ++ [min(List.last(xs) + 0.6, 100.0)]

    # No bar runs past the right edge of the drawing.
    points
    |> Enum.zip(nexts)
    |> Enum.map(fn {p, next} -> {p, Float.round(min(max(next - p.x, 0.3), 100.0 - p.x), 3)} end)
  end

  defp args_text(args) when is_map(args) do
    text =
      case Jason.encode(args) do
        {:ok, json} -> json
        _ -> inspect(args, limit: 20, printable_limit: @max_args_chars)
      end

    Trace.excerpt(text, @max_args_chars)
  end

  defp args_text(args) when is_binary(args), do: Trace.excerpt(args, @max_args_chars)
  defp args_text(nil), do: ""
  defp args_text(args), do: Trace.excerpt(inspect(args, limit: 20), @max_args_chars)

  @doc """
  Text cut to the first #{@max_output_chars} characters, with a note saying
  how much was left out.
  """
  @spec cut(term()) :: String.t()
  def cut(text) when is_binary(text) do
    length = String.length(text)

    if length > @max_output_chars,
      do:
        String.slice(text, 0, @max_output_chars) <>
          "\n… #{length - @max_output_chars} more characters not shown",
      else: text
  end

  def cut(other), do: cut(to_string(other))
end
