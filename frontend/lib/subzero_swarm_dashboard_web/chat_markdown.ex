defmodule SubzeroSwarmDashboardWeb.ChatMarkdown do
  @moduledoc """
  Renderer for the swarm agents' authoring dialect — `**bold**`, `*italic*` /
  `_italic_`, `` `code` ``, `[text](url)`, backslash escapes. Same tokenization
  as the transport-side renderer of this dialect; emits an HTML-safe iolist for
  the browser. Every text segment is escaped — never `raw/1` upstream of this.
  Deliberate divergence: `tg:` URLs render as plain text (in the dashboard they
  would deep-link the OPERATOR's own client, not the end user's).
  """

  @markers ["\\", "*", "_", "`", "[", "]"]

  @spec render(binary() | nil) :: {:safe, iodata()}
  def render(md) when is_binary(md),
    do: {:safe, md |> tokens([]) |> Enum.map(&html/1)}

  def render(nil), do: {:safe, ""}
  def render(other), do: other |> to_string() |> render()

  defp tokens("", acc), do: Enum.reverse(acc)

  defp tokens(s, acc) do
    case entity(s) do
      {tok, rest} ->
        tokens(rest, [tok | acc])

      :none ->
        {lit, rest} = literal(s)
        tokens(rest, [{:text, lit} | acc])
    end
  end

  defp entity(<<"\\", c::utf8, rest::binary>>) do
    s = <<c::utf8>>
    if s in @markers, do: {{:text, s}, rest}, else: :none
  end

  defp entity("**" <> rest) do
    case close(rest, "**") do
      {inner, after_} when inner != "" -> {{:bold, inner}, after_}
      _ -> :none
    end
  end

  defp entity("`" <> rest) do
    case String.split(rest, "`", parts: 2) do
      [inner, after_] when inner != "" -> {{:code, inner}, after_}
      _ -> :none
    end
  end

  defp entity("[" <> rest) do
    case String.split(rest, "](", parts: 2) do
      [text, after_text] when text != "" ->
        case take_url(after_text, 0, "") do
          {url, after_url} when url != "" -> {{:link, text, url}, after_url}
          :none -> :none
        end

      _ ->
        :none
    end
  end

  defp entity("*" <> rest), do: italic(rest, "*")
  defp entity("_" <> rest), do: italic(rest, "_")
  defp entity(_), do: :none

  defp italic(rest, mark) do
    case close(rest, mark) do
      {inner, after_} when inner != "" -> {{:italic, inner}, after_}
      _ -> :none
    end
  end

  defp close(str, marker), do: close(str, marker, "")
  defp close("", _marker, _acc), do: :none

  defp close(<<"\\", c::utf8, rest::binary>>, marker, acc),
    do: close(rest, marker, acc <> "\\" <> <<c::utf8>>)

  defp close(str, marker, acc) do
    if String.starts_with?(str, marker) do
      {acc, String.replace_prefix(str, marker, "")}
    else
      <<c::utf8, rest::binary>> = str
      close(rest, marker, acc <> <<c::utf8>>)
    end
  end

  defp literal(s) do
    case Regex.run(~r/^[^\\*_`\[\]]+/u, s) do
      [run] -> {run, String.replace_prefix(s, run, "")}
      nil -> {String.slice(s, 0, 1), String.slice(s, 1..-1//1)}
    end
  end

  defp take_url("", _depth, _acc), do: :none
  defp take_url(<<")", rest::binary>>, 0, acc), do: {acc, rest}
  defp take_url(<<")", rest::binary>>, depth, acc), do: take_url(rest, depth - 1, acc <> ")")
  defp take_url(<<"(", rest::binary>>, depth, acc), do: take_url(rest, depth + 1, acc <> "(")

  defp take_url(<<c::utf8, _rest::binary>>, _depth, _acc) when c in [?\s, ?\n, ?\r, ?\t],
    do: :none

  defp take_url(<<c::utf8, rest::binary>>, depth, acc),
    do: take_url(rest, depth, acc <> <<c::utf8>>)

  defp html({:text, t}), do: esc_text(t)
  defp html({:bold, t}), do: ["<b>", esc_text(t), "</b>"]
  defp html({:italic, t}), do: ["<i>", esc_text(t), "</i>"]
  defp html({:code, t}), do: ["<code>", esc(t), "</code>"]

  defp html({:link, text, url}) do
    if safe_url?(url) do
      [
        ~s(<a href="),
        esc_attr(url),
        ~s(" target="_blank" rel="noopener noreferrer">),
        esc_text(text),
        "</a>"
      ]
    else
      esc_text(text)
    end
  end

  defp esc_text(t), do: t |> deescape() |> esc()
  defp deescape(t), do: String.replace(t, ~r/\\([\\*_`\[\]])/, "\\1")

  defp esc(t) do
    t
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp esc_attr(url), do: url |> esc() |> String.replace("\"", "&quot;")

  defp safe_url?(url), do: String.match?(to_string(url), ~r{^(https?|mailto):}i)
end
