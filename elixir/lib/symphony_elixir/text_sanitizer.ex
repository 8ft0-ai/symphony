defmodule SymphonyElixir.TextSanitizer do
  @moduledoc """
  Sanitizes internal control text before Symphony persists user-visible content.
  """

  @system_reminder_pattern Regex.compile!(
                             ~s"<system-reminder\\b(?:[^>\"']|\"[^\"]*\"|'[^']*')*>.*?</system-reminder>",
                             "is"
                           )
  @system_reminder_line_pattern Regex.compile!(
                                  ~s"(^|\\r?\\n)[ \\t]*<system-reminder\\b(?:[^>\"']|\"[^\"]*\"|'[^']*')*>.*?</system-reminder>[ \\t]*(\\r?\\n|$)",
                                  "is"
                                )

  @spec sanitize_user_visible_text(String.t()) :: String.t()
  def sanitize_user_visible_text(text) when is_binary(text) do
    without_reminder_lines =
      Regex.replace(@system_reminder_line_pattern, text, &replace_system_reminder_line/3)

    Regex.replace(@system_reminder_pattern, without_reminder_lines, "")
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

  defp replace_system_reminder_line(_match, prefix, suffix)
       when prefix != "" and suffix != "" do
    prefix
  end

  defp replace_system_reminder_line(_match, _prefix, _suffix), do: ""
end
