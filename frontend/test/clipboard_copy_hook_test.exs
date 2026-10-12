defmodule SubzeroSwarmDashboard.ClipboardCopyHookTest do
  use ExUnit.Case, async: true

  test "clipboard hook behavior" do
    {output, status} =
      System.cmd("node", ["--test", "test/js/clipboard_copy_test.mjs"], stderr_to_stdout: true)

    assert status == 0, output
  end
end
