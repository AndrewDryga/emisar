defmodule Emisar.Runbooks.Runbook.ChangesetTest do
  use ExUnit.Case, async: true
  import Emisar.DataCase, only: [errors_on: 1]
  alias Emisar.Runbooks
  alias Emisar.Runbooks.Runbook

  defp base_attrs(extra) do
    Map.merge(
      %{
        slug: "inspect-fleet",
        title: "Inspect fleet",
        description: "Confirm the fleet is ready.",
        draft_definition: valid_definition()
      },
      extra
    )
  end

  defp create(extra) do
    Runbook.Changeset.create(Ecto.UUID.generate(), Ecto.UUID.generate(), base_attrs(extra))
  end

  describe "create/3 metadata byte ceilings" do
    test "accepts multi-byte metadata inside both the character and byte ceilings" do
      changeset =
        create(%{title: String.duplicate("設", 40), description: String.duplicate("設", 2_000)})

      assert changeset.valid?
    end

    test "rejects a description inside the character limit but past the byte ceiling" do
      # 4,000 CJK characters sit under the 4,096-character limit and still weigh
      # 12,000 bytes. The character limit alone let this overflow the MCP
      # projection budget, which is measured in bytes.
      description = String.duplicate("設", 4_000)
      assert length(String.graphemes(description)) < 4_096
      assert byte_size(description) > Runbooks.metadata_limit!(:description_bytes)

      changeset = create(%{description: description})

      refute changeset.valid?

      assert "should be at most #{Runbooks.metadata_limit!(:description_bytes)} byte(s)" in errors_on(
               changeset
             ).description
    end

    test "rejects a title inside the character limit but past the byte ceiling" do
      # One family emoji is a single grapheme carrying 25 bytes, so 80 of them
      # satisfy an 80-character title and still weigh 2,000 bytes.
      title = String.duplicate("👨‍👩‍👧‍👦", 80)
      assert length(String.graphemes(title)) == 80
      assert byte_size(title) > Runbooks.metadata_limit!(:title_bytes)

      changeset = create(%{title: title})

      refute changeset.valid?

      assert "should be at most #{Runbooks.metadata_limit!(:title_bytes)} byte(s)" in errors_on(
               changeset
             ).title
    end

    test "still rejects a title past the character limit" do
      changeset = create(%{title: String.duplicate("a", 81)})

      refute changeset.valid?
      assert "should be at most 80 character(s)" in errors_on(changeset).title
    end
  end

  defp valid_definition do
    %{
      "schema_version" => 1,
      "context_markdown" => "Inspect before changing anything.",
      "inputs" => [],
      "stages" => [
        %{
          "id" => "inspect",
          "title" => "Inspect",
          "mode" => "sequential",
          "steps" => [
            %{
              "id" => "observe",
              "pack" => %{"id" => "linux-core"},
              "action" => "linux.uptime",
              "targets" => %{"selection" => "all", "refs" => ["group:edge"]},
              "args" => %{},
              "outputs" => [],
              "success" => [],
              "wait" => nil
            }
          ]
        }
      ]
    }
  end
end
