defmodule SubzeroSwarmDashboard.PrivacyRedactorTest do
  use ExUnit.Case, async: true

  alias SubzeroSwarmDashboard.PrivacyRedactor

  test "mask_cid masks positive and negative telegram cids without scrubbing other digits" do
    text = "dm=tg:987654321:0 group=tg:-1001234567890:42 total=12345"

    assert PrivacyRedactor.mask_cid(text) == "dm=tg:••• group=tg:••• total=12345"
  end

  test "mask_cid masks legacy underscore telegram cids" do
    assert PrivacyRedactor.mask_cid("legacy tg_987654321_0 remains") ==
             "legacy tg:••• remains"
  end

  test "mask_identity redacts nested consumer extension payloads while keeping structure" do
    payload = %{
      "items" => [
        %{
          "user" => %{
            "handle" => "@canary_h4ndle",
            "name" => "Canary Q. Name",
            "count" => 2
          },
          "session_id" => "tg:987654321:0",
          "mode" => "scout",
          "opt_out" => false,
          "count" => 7,
          "note" => "seen in tg:-1001234567890:9"
        }
      ],
      "count" => 1
    }

    redacted = PrivacyRedactor.mask_identity(payload)
    [item] = redacted["items"]

    assert item["user"]["handle"] == "•••"
    assert item["user"]["name"] == "•••"
    assert item["user"]["count"] == 2
    assert item["session_id"] == "•••"
    assert item["mode"] == "scout"
    assert item["opt_out"] == false
    assert item["count"] == 7
    assert item["note"] == "seen in tg:•••"
    assert redacted["count"] == 1
  end

  test "mask_identity supports atom keys and nested identity fields under non-identity keys" do
    payload = %{
      profile: %{
        username: "canary_user",
        first_name: "Canary",
        meta: %{
          last_name: "Name",
          mode: "scout",
          count: 3,
          warning: "conversation tg_987654321_0"
        }
      },
      active: true
    }

    redacted = PrivacyRedactor.mask_identity(payload)

    assert redacted.profile.username == "•••"
    assert redacted.profile.first_name == "•••"
    assert redacted.profile.meta.last_name == "•••"
    assert redacted.profile.meta.mode == "scout"
    assert redacted.profile.meta.count == 3
    assert redacted.profile.meta.warning == "conversation tg:•••"
    assert redacted.active == true
  end

  test "mask_text uses fixed-length output for all binary inputs" do
    assert PrivacyRedactor.mask_text("") == "▪▪▪▪▪"
    assert PrivacyRedactor.mask_text("short") == "▪▪▪▪▪"
    assert PrivacyRedactor.mask_text("CANARY-TEXT with much more content") == "▪▪▪▪▪"
    assert String.length(PrivacyRedactor.mask_text("CANARY-TEXT")) == 5
  end

  test "non-binary values pass through for all public functions" do
    assert PrivacyRedactor.mask_cid(123) == 123
    assert PrivacyRedactor.mask_cid([:tg, 1]) == [:tg, 1]
    assert PrivacyRedactor.mask_identity(nil) == nil
    assert PrivacyRedactor.mask_identity(42) == 42
    assert PrivacyRedactor.mask_identity(false) == false
    assert PrivacyRedactor.mask_text(nil) == nil
    assert PrivacyRedactor.mask_text(42) == 42
    assert PrivacyRedactor.mask_text(false) == false
  end
end
