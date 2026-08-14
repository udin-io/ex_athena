defmodule ExAthena.Compactors.EpisodicArchive do
  @moduledoc """
  Fifth pipeline stage — episodic archive with BM25 recall.

  Before `Summary` compresses the middle of history into a paragraph,
  this stage slices that middle into discrete episodes and stores their
  text in `state.meta[:episodic_archive]`. On every pipeline run it
  also checks whether any archived episode is relevant to the current
  turn and injects matching episodes into the compact_view.

  ## Why this over RAG

  Agent conversations have strong temporal structure — turn N depends
  on N-1 (tool call + result pairs). Embedding-based retrieval doesn't
  model that dependency. BM25 on code/tool output works better because
  the model asks about specific function names, file paths, and error
  strings — exact-token matches, not semantic proximity.

  ## What this solves

  Summary's biggest weakness: "found bug at line 47 of auth.ex"
  compresses to "the agent investigated auth". The finding — file, line,
  what the bug was — is gone. When the model needs that detail later it
  re-reads the file. EpisodicArchive keeps the text of each episode in
  a sidecar and injects it back when it scores above threshold.

  ## Configuration

      config :ex_athena, :compactor,
        episodic_episode_size: 8,        # messages per episode
        episodic_top_k: 2,               # episodes recalled per turn
        episodic_score_threshold: 1.5,   # minimum BM25 score to recall
        episodic_recall_chars: 800       # max chars per recalled episode
  """

  @behaviour ExAthena.Compactor.Stage

  alias ExAthena.Loop.State
  alias ExAthena.Messages.Message

  @default_episode_size 8
  @default_top_k 2
  @default_score_threshold 1.5
  @default_recall_chars 800
  @live_suffix_count 6

  @impl true
  def name, do: :episodic_archive

  @impl true
  def compact_stage(%State{messages: messages} = state, estimate) do
    archive = Map.get(state.meta, :episodic_archive, [])
    pin_floor = pin_floor(state)
    total = length(messages)
    middle_end = max(pin_floor, total - @live_suffix_count)

    middle =
      messages
      |> Enum.slice(pin_floor, middle_end - pin_floor)
      |> Enum.reject(&skip_for_archive?/1)

    {new_archive, archived_count} = archive_episodes(middle, archive, episode_size(state))

    live_suffix = Enum.drop(messages, middle_end)
    query = extract_query(live_suffix)
    recalled = recall_episodes(new_archive, query, top_k(state), score_threshold(state))

    if archived_count == 0 and recalled == [] do
      :skip
    else
      new_state = put_in(state.meta[:episodic_archive], new_archive)

      new_state =
        if recalled != [] do
          inject_recall(new_state, recalled, recall_chars(state))
        else
          new_state
        end

      {:ok, new_state, estimate}
    end
  end

  # ── Episode archiving ─────────────────────────────────────────────

  # Skip compaction artefacts so already-summarised turns don't get
  # double-archived.
  defp skip_for_archive?(%Message{name: name})
       when name in ["compactor_summary", "microcompact", "episodic_recall"],
       do: true

  defp skip_for_archive?(_), do: false

  defp archive_episodes(messages, existing, size) do
    existing_fps =
      existing
      |> Enum.flat_map(& &1.fingerprints)
      |> MapSet.new()

    new_msgs = Enum.reject(messages, fn m -> MapSet.member?(existing_fps, fingerprint(m)) end)

    if new_msgs == [] do
      {existing, 0}
    else
      episodes = new_msgs |> Enum.chunk_every(size) |> Enum.map(&build_episode/1)
      {existing ++ episodes, length(episodes)}
    end
  end

  defp build_episode(messages) do
    %{
      id: generate_id(),
      text: extract_text(messages),
      fingerprints: Enum.map(messages, &fingerprint/1)
    }
  end

  defp fingerprint(%Message{role: role, content: content, name: name}) do
    :erlang.phash2({role, content, name})
  end

  # ── BM25 recall ───────────────────────────────────────────────────

  defp recall_episodes([], _query, _k, _threshold), do: []
  defp recall_episodes(_archive, "", _k, _threshold), do: []

  defp recall_episodes(archive, query, k, threshold) do
    query_terms = tokenize(query)

    if query_terms == [] do
      []
    else
      doc_term_lists = Enum.map(archive, fn ep -> tokenize(ep.text) end)

      avg_doc_len =
        doc_term_lists
        |> Enum.map(&length/1)
        |> then(fn lens ->
          if lens == [], do: 1, else: Enum.sum(lens) / length(lens)
        end)

      df_map = build_df_map(doc_term_lists)
      n = length(archive)

      archive
      |> Enum.zip(doc_term_lists)
      |> Enum.map(fn {ep, doc_terms} ->
        {bm25(query_terms, doc_terms, avg_doc_len, n, df_map), ep}
      end)
      |> Enum.filter(fn {score, _} -> score >= threshold end)
      |> Enum.sort_by(&elem(&1, 0), :desc)
      |> Enum.take(k)
      |> Enum.map(&elem(&1, 1))
    end
  end

  defp bm25(query_terms, doc_terms, avg_doc_len, n, df_map) do
    k1 = 1.5
    b = 0.75
    doc_len = length(doc_terms)
    tf_map = Enum.frequencies(doc_terms)

    Enum.sum(
      Enum.map(query_terms, fn term ->
        tf = Map.get(tf_map, term, 0)
        df = Map.get(df_map, term, 0)
        idf = :math.log((n - df + 0.5) / (df + 0.5) + 1)
        tf_norm = tf * (k1 + 1) / (tf + k1 * (1 - b + b * doc_len / avg_doc_len))
        idf * tf_norm
      end)
    )
  end

  defp build_df_map(doc_term_lists) do
    Enum.reduce(doc_term_lists, %{}, fn terms, acc ->
      terms
      |> Enum.uniq()
      |> Enum.reduce(acc, fn term, acc -> Map.update(acc, term, 1, &(&1 + 1)) end)
    end)
  end

  # ── Text extraction ───────────────────────────────────────────────

  defp extract_text(messages) do
    messages
    |> Enum.map_join(" ", &message_text/1)
    |> String.slice(0, 4000)
  end

  defp extract_query(messages) do
    messages
    |> Enum.filter(&(&1.role in [:user, :assistant]))
    |> Enum.map_join(" ", &message_text/1)
    |> String.slice(0, 2000)
  end

  defp message_text(%Message{role: :assistant, content: content, tool_calls: calls}) do
    text = if is_binary(content), do: content, else: ""

    calls_text =
      if is_list(calls) do
        Enum.map_join(calls, " ", fn
          %{name: name, arguments: args} when is_map(args) ->
            path = Map.get(args, "path") || Map.get(args, "command") || ""
            "#{name} #{path}"

          %{name: name} ->
            name

          _ ->
            ""
        end)
      else
        ""
      end

    "#{text} #{calls_text}"
  end

  defp message_text(%Message{role: :tool, tool_results: results}) when is_list(results) do
    Enum.map_join(results, " ", fn r -> r.content |> to_string() |> String.slice(0, 200) end)
  end

  defp message_text(%Message{content: content}) when is_binary(content), do: content
  defp message_text(_), do: ""

  # ── Tokenisation ──────────────────────────────────────────────────

  # Split on whitespace/punctuation, lowercase, drop stop words and
  # single-char tokens. Preserves file paths, function names, error strings.

  @stop_words MapSet.new(~w(
    the a an and or is are was were be been being have has had
    do does did will would could should may might shall can
    to of in on at for with by from that this these those it
    its i you he she we they not no nil true false
  ))

  defp tokenize(text) do
    text
    |> String.downcase()
    |> String.split(~r/[\s,;:!?()\[\]{}<>'"]+/)
    |> Enum.reject(&(String.length(&1) < 2))
    |> Enum.reject(&MapSet.member?(@stop_words, &1))
  end

  # ── Recall injection ──────────────────────────────────────────────

  defp inject_recall(state, episodes, max_chars) do
    body =
      Enum.map_join(episodes, "\n\n", fn ep ->
        "[recalled episode #{ep.id}]\n#{String.slice(ep.text, 0, max_chars)}"
      end)

    recall_msg = %Message{
      role: :assistant,
      content: "[episodic recall — relevant prior context]\n\n#{body}",
      name: "episodic_recall"
    }

    base_view = Map.get(state.meta, :compact_view, state.messages)
    floor = pin_floor(state)
    {prefix, rest} = Enum.split(base_view, floor)
    new_view = prefix ++ [recall_msg] ++ rest

    %{state | meta: Map.put(state.meta, :compact_view, new_view)}
  end

  # ── Helpers ───────────────────────────────────────────────────────

  defp generate_id do
    :crypto.strong_rand_bytes(4) |> Base.url_encode64(padding: false)
  end

  defp pin_floor(%State{meta: meta}) do
    Map.get(meta, :memory_count, 0) +
      Map.get(meta, :preloaded_skill_count, 0) +
      Map.get(meta, :pinned_prefix_count, 1)
  end

  defp episode_size(%State{meta: meta}),
    do:
      Map.get(meta, :episodic_episode_size) || cfg(:episodic_episode_size, @default_episode_size)

  defp top_k(%State{meta: meta}),
    do: Map.get(meta, :episodic_top_k) || cfg(:episodic_top_k, @default_top_k)

  defp score_threshold(%State{meta: meta}),
    do:
      Map.get(meta, :episodic_score_threshold) ||
        cfg(:episodic_score_threshold, @default_score_threshold)

  defp recall_chars(%State{meta: meta}),
    do:
      Map.get(meta, :episodic_recall_chars) || cfg(:episodic_recall_chars, @default_recall_chars)

  defp cfg(key, default) do
    case Application.get_env(:ex_athena, :compactor) do
      kw when is_list(kw) -> Keyword.get(kw, key, default)
      m when is_map(m) -> Map.get(m, key, default)
      _ -> default
    end
  end
end
