defmodule SubzeroSwarmDashboardWeb.ChatMarkdownTest do
  use ExUnit.Case, async: true

  alias SubzeroSwarmDashboardWeb.ChatMarkdown

  defp html(md), do: md |> ChatMarkdown.render() |> Phoenix.HTML.safe_to_string()

  # dialect cases mirror genswarms-telegram's Format suite so the two renderers
  # of the agents' authoring dialect cannot silently diverge
  test "bold, italic, code, link" do
    assert html("**b** *i* _j_ `c`") == "<b>b</b> <i>i</i> <i>j</i> <code>c</code>"

    assert html("[docs](https://x.dev/a)") ==
             ~s(<a href="https://x.dev/a" target="_blank" rel="noopener noreferrer">docs</a>)
  end

  test "unclosed markers stay literal" do
    assert html("**nope") == "**nope"
    assert html("`nope") == "`nope"
    assert html("[text](") == "[text]("
  end

  test "backslash escapes render the literal marker" do
    assert html(~S"\*not italic\*") == "*not italic*"
  end

  test "HTML in content is escaped, always" do
    assert html("<script>alert(1)</script>") ==
             "&lt;script&gt;alert(1)&lt;/script&gt;"

    assert html("**<b>bold</b>**") == "<b>&lt;b&gt;bold&lt;/b&gt;</b>"
  end

  test "unsafe link schemes render as text" do
    assert html("[x](javascript:alert(1))") == "x"
    # deliberate divergence from Format.safe_url?: tg: would deep-link the
    # OPERATOR's client — plain text here. Do not "fix" this to match Format.
    assert html("[x](tg://resolve?domain=y)") == "x"
  end

  test "mailto is allowed" do
    assert html("[m](mailto:a@b.c)") ==
             ~s(<a href="mailto:a@b.c" target="_blank" rel="noopener noreferrer">m</a>)
  end

  test "nil and non-binary degrade" do
    assert html(nil) == ""
  end
end
