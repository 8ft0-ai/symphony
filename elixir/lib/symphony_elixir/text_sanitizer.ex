defmodule SymphonyElixir.TextSanitizer do
  @moduledoc """
  Sanitizes internal control text before Symphony persists user-visible content.
  """

  @system_reminder_pattern ~r/<system-reminder\b[^>]*>.*?<\/system-reminder>/is

  @spec sanitize_user_visible_text(String.t()) :: String.t()
  def sanitize_user_visible_text(text) when is_binary(text) do
    Regex.replace(@system_reminder_pattern, text, "")
  end

  @spec sanitize_graphql_value(term()) :: term()
  def sanitize_graphql_value(value) when is_binary(value), do: sanitize_user_visible_text(value)

  def sanitize_graphql_value(value) when is_list(value) do
    Enum.map(value, &sanitize_graphql_value/1)
  end

  def sanitize_graphql_value(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {key, sanitize_graphql_value(nested)} end)
  end

  def sanitize_graphql_value(value), do: value
end
