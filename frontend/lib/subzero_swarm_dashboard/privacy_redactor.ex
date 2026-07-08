defmodule SubzeroSwarmDashboard.PrivacyRedactor do
  @moduledoc """
  Pure redaction helpers for the dashboard privacy mode.
  """

  @masked_identity "•••"
  @masked_text "▪▪▪▪▪"
  @cid_pattern ~r/tg:-?\d+:\d+|tg_\d+_\d+/
  @identity_keys MapSet.new(~w(
    chat_id
    cid
    conversation_id
    first_name
    from
    handle
    identity
    label
    last_name
    name
    session_id
    user
    user_id
    username
  ))

  @doc """
  Masks Telegram conversation-id-shaped substrings in free text.
  """
  def mask_cid(text) when is_binary(text) do
    Regex.replace(@cid_pattern, text, "tg:#{@masked_identity}")
  end

  def mask_cid(other), do: other

  @doc """
  Deep-walks maps and lists, masking identity-bearing keys and cid-shaped text.
  """
  def mask_identity(%{} = map) do
    Map.new(map, fn {key, value} ->
      value =
        if identity_key?(key) do
          mask_identity_value(value)
        else
          mask_identity(value)
        end

      {key, value}
    end)
  end

  def mask_identity(list) when is_list(list), do: Enum.map(list, &mask_identity/1)
  def mask_identity(value) when is_binary(value), do: mask_cid(value)
  def mask_identity(value), do: value

  @doc """
  Masks free text with a fixed-length placeholder.
  """
  def mask_text(nil), do: nil
  def mask_text(text) when is_binary(text), do: @masked_text
  def mask_text(other), do: other

  defp mask_identity_value(value) when is_map(value) or is_list(value), do: mask_identity(value)
  defp mask_identity_value(_value), do: @masked_identity

  defp identity_key?(key) when is_atom(key),
    do: MapSet.member?(@identity_keys, Atom.to_string(key))

  defp identity_key?(key) when is_binary(key), do: MapSet.member?(@identity_keys, key)
  defp identity_key?(_key), do: false
end
