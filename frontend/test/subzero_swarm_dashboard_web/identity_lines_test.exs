defmodule SubzeroSwarmDashboardWeb.IdentityLinesTest do
  # identity_lines/3 must never render the same text twice: an adapter label
  # that IS the handle ("@pouya24300" with handle "pouya24300") used to produce
  # primary "@pouya24300" + secondary "@pouya24300" on the Sessions page.
  use ExUnit.Case, async: true

  import SubzeroSwarmDashboardWeb.CoreComponents, only: [identity_lines: 3]

  @user %{"handle" => "pouya24300", "name" => nil}

  test "label equal to the @handle falls back to the cid for the secondary line" do
    lines = identity_lines(@user, "tg:42:0", "@pouya24300")
    assert lines.primary == "@pouya24300"
    refute lines.secondary == "@pouya24300"
  end

  test "a label different from the handle keeps the @handle secondary" do
    lines = identity_lines(@user, "tg:42:0", "Pouya")
    assert lines.primary == "Pouya"
    assert lines.secondary == "@pouya24300"
  end

  # Prod 2026-07-07: a forum group produced two rows both labeled the raw chat
  # id ("-1003762806404") — indistinguishable from each other and not a person.
  test "a group label that IS the raw chat id yields the Group chat treatment" do
    lines = identity_lines(nil, "tg:-1003762806404:1278", "-1003762806404")
    assert lines.primary == "Group chat"
    assert lines.monogram == "⌗"
  end

  test "two topics of the same forum group get distinct secondary lines" do
    general = identity_lines(nil, "tg:-1003762806404:0", "-1003762806404")
    topic = identity_lines(nil, "tg:-1003762806404:1278", "-1003762806404")
    assert general.secondary != topic.secondary
    assert topic.secondary =~ "1278"
  end

  test "a real group title label is kept as the primary line" do
    lines = identity_lines(nil, "tg:-1003762806404:0", "GenLayer Community")
    assert lines.primary == "GenLayer Community"
  end
end
