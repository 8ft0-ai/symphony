defmodule SymphonyElixir.TextSanitizerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.TextSanitizer

  test "sanitize_user_visible_text returns empty input unchanged" do
    assert TextSanitizer.sanitize_user_visible_text("") == ""
  end

  test "sanitize_user_visible_text removes standalone reminder lines without leaving blank lines" do
    text = "hello\n<system-reminder>internal only</system-reminder>"

    assert TextSanitizer.sanitize_user_visible_text(text) == "hello"
  end

  test "sanitize_user_visible_text handles quoted attributes and preserves surrounding lines" do
    text = """
    hello
    <system-reminder data-note="a>b">internal only</system-reminder>
    world
    """

    assert TextSanitizer.sanitize_user_visible_text(text) == "hello\nworld\n"
  end

  test "sanitize_user_visible_text leaves malformed reminder tags unchanged" do
    text = "<system-reminder>internal only"

    assert TextSanitizer.sanitize_user_visible_text(text) == text
  end

  test "sanitize_graphql_value sanitizes nested strings and preserves non-binary values" do
    value = %{
      "body" => "hello\n<system-reminder>strip me</system-reminder>",
      "nested" => [%{"note" => "keep\n<system-reminder>remove</system-reminder>"}],
      "count" => 1,
      "enabled" => true
    }

    assert TextSanitizer.sanitize_graphql_value(value) == %{
             "body" => "hello",
             "nested" => [%{"note" => "keep"}],
             "count" => 1,
             "enabled" => true
           }
  end
end
