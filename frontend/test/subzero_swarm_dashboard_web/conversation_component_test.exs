defmodule SubzeroSwarmDashboardWeb.ConversationComponentTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  alias SubzeroSwarmDashboardWeb.CoreComponents

  defp render_conv(turns),
    do: render_component(&CoreComponents.conversation/1, id: "conv-t", turns: turns)

  test "markdown renders inside bubbles; sides follow roles" do
    html =
      render_conv([
        %{"role" => "user", "content" => "hola **jefe**"},
        %{"role" => "assistant", "content" => "**Dos** lanes"}
      ])

    assert html =~ "msg-in"
    assert html =~ "msg-out"
    assert html =~ "hola <b>jefe</b>"
    assert html =~ "<b>Dos</b> lanes"
    refute html =~ "**"
  end

  test "tail only on the last message of a same-role run" do
    html =
      render_conv([
        %{"role" => "assistant", "content" => "uno"},
        %{"role" => "assistant", "content" => "dos"},
        %{"role" => "user", "content" => "tres"}
      ])

    # exactly two tails: end of the assistant run + the (single) user run
    assert html |> String.split("msg-tail") |> length() == 3
  end

  test "notes render centered, not as bubbles; no user/assistant labels anywhere" do
    html =
      render_conv([
        %{"role" => "assistant", "content" => "📇 (sent the user a rich card: X)", "kind" => "note"}
      ])

    assert html =~ "msg-note"
    refute html =~ "msg-bubble"
    refute html =~ "chat-header"
  end

  test "at renders a LocalTime stamp; auto renders the tag" do
    html =
      render_conv([
        %{"role" => "assistant", "content" => "tip", "at" => 1_782_000_000, "auto" => true}
      ])

    assert html =~ ~s(phx-hook="LocalTime")
    assert html =~ ~s(data-ts="1782000000")
    assert html =~ "msg-auto"
  end

  test "missing optional fields degrade to plain bubbles" do
    html = render_conv([%{"role" => "user", "content" => "solo texto"}])
    refute html =~ "LocalTime"
    refute html =~ "msg-auto"
    assert html =~ "solo texto"
  end

  test "container carries the ConversationDays hook and the stable id" do
    html = render_conv([%{"role" => "user", "content" => "x"}])
    assert html =~ ~s(id="conv-t")
    assert html =~ ~s(phx-hook="ConversationDays")
  end
end
