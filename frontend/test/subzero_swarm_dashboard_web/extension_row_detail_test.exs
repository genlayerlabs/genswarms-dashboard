defmodule SubzeroSwarmDashboardWeb.ExtensionRowDetailTest do
  # Extension-table row detail (ported from micromarkets' Markets page):
  # a row may carry "detail" — a list of %{"label", "value", optional "link"}
  # maps — rendered as an expandable definition grid under the row. Columns
  # may declare "link": true to render http(s) values as anchors.
  #
  # The link guard is FAIL-CLOSED on purpose: anchors render only for real
  # absolute http(s) URLs. Privacy mode masks every binary row value to "•••",
  # which must degrade to plain text — an <a href="•••"> would navigate to a
  # broken relative path and, worse, invert the masking guarantee if a host
  # ever masked the label but not the href.
  use SubzeroSwarmDashboardWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  # Deliver straight to the view process — a PubSub broadcast is async and
  # can race the next render/1.
  defp broadcast(view, snap), do: send(view.pid, {:snapshot, snap})

  defp page_snap(rows, columns) do
    %{
      "extensions" => %{
        "dashboard_pages" => [
          %{
            "id" => "markets",
            "label" => "Markets",
            "sections" => [
              %{
                "type" => "table",
                "title" => "Open markets",
                "columns" => columns,
                "rows" => rows
              }
            ]
          }
        ]
      }
    }
  end

  @columns [
    %{"key" => "id", "label" => "Id"},
    %{"key" => "question", "label" => "Question"},
    %{"key" => "url", "label" => "Link", "link" => true}
  ]

  test "a row with detail expands into a definition grid and collapses again", %{conn: conn} do
    rows = [
      %{
        "id" => "m1",
        "question" => "Will it rain?",
        "url" => "https://example.com/m1",
        "detail" => [
          %{"label" => "type", "value" => "binary"},
          %{"label" => "contract", "value" => "0xabc", "link" => "https://scan.example/0xabc"}
        ]
      }
    ]

    {:ok, view, _html} = live(conn, "/extensions/markets")
    broadcast(view, page_snap(rows, @columns))

    html = render(view)
    refute html =~ "ext-detail-row"
    # the toggle key is the STABLE row id, never the sort-relative index
    assert html =~ ~s(phx-value-key="0|m1")

    html = view |> element(~s(tr[phx-value-key="0|m1"])) |> render_click()
    assert html =~ "ext-detail-row"
    assert html =~ "binary"
    assert html =~ ~s(href="https://scan.example/0xabc")

    html = view |> element(~s(tr.ext-has-detail[phx-value-key="0|m1"])) |> render_click()
    refute html =~ "ext-detail-row"
  end

  test "link columns render anchors for http values — and plain text for masked ones", %{
    conn: conn
  } do
    rows = [
      %{"id" => "m1", "question" => "q", "url" => "https://example.com/m1"},
      %{"id" => "m2", "question" => "q2", "url" => "•••"}
    ]

    {:ok, view, _html} = live(conn, "/extensions/markets")
    broadcast(view, page_snap(rows, @columns))
    html = render(view)

    assert html =~ ~s(href="https://example.com/m1")
    # the masked value must degrade to text — never an anchor
    refute html =~ ~s(href="•••")
  end

  test "rows without detail keep the plain single-row rendering", %{conn: conn} do
    rows = [%{"id" => "m1", "question" => "q", "url" => "https://example.com/m1"}]

    {:ok, view, _html} = live(conn, "/extensions/markets")
    broadcast(view, page_snap(rows, @columns))
    html = render(view)

    refute html =~ "ext-has-detail"
    refute html =~ "ext-detail-row"
  end
end
