defmodule EmisarWeb.MCP.RunbookContractTest do
  use ExUnit.Case, async: true
  alias Emisar.Runbooks
  alias EmisarWeb.MCP.RunbookContract

  @family %{published_ref: "inspect-fleet@3", draft_ref: "inspect-fleet@4"}

  describe "project/2" do
    test "keeps metadata separate and projects the canonical definition losslessly" do
      definition = valid_definition()

      runbook = %Runbooks.Runbook{
        slug: "inspect-fleet",
        version: 3,
        title: "Inspect fleet",
        description: "Confirm the fleet is ready.",
        definition: definition
      }

      assert {:ok, projection} = RunbookContract.project(runbook, @family)

      assert projection == %{
               runbook_ref: "inspect-fleet@3",
               status: "published",
               definition_sha256: Runbooks.definition_digest(definition),
               title: "Inspect fleet",
               description: "Confirm the fleet is ready.",
               definition: definition,
               summary: %{input_count: 1, stage_count: 1, step_count: 1},
               family: @family
             }
    end

    test "preserves nullable description" do
      runbook = %Runbooks.Runbook{
        slug: "inspect-fleet",
        version: 1,
        title: "Inspect fleet",
        description: nil,
        definition: valid_definition()
      }

      assert {:ok, %{description: nil}} = RunbookContract.project(runbook, @family)
    end

    test "fails closed when the stored definition is not canonical" do
      runbook = %Runbooks.Runbook{
        slug: "legacy",
        version: 1,
        title: "Legacy",
        definition: %{"steps" => []}
      }

      assert RunbookContract.project(runbook, @family) == {:error, :incomplete_contract}
    end

    test "reports an oversized runbook as oversized, not as a missing one" do
      runbook = oversized_runbook()

      assert {:error, {:runbook_too_large, bytes}} = RunbookContract.project(runbook, @family)
      assert bytes > RunbookContract.max_projection_bytes()
    end

    test "the declared envelope covers every wrapper around the bounded values" do
      # The budget is definition + title + description + envelope, so the
      # envelope is the only term not pinned by an authoring limit. Measure it
      # at its worst case — longest refs, both family sides present — so the
      # derivation cannot quietly drift under a growing projection.
      slug = String.duplicate("a", 79)
      family = %{published_ref: "#{slug}@999999999", draft_ref: "#{slug}@999999999"}

      runbook = %Runbooks.Runbook{
        slug: slug,
        version: 999_999_999,
        title: "",
        description: "",
        definition: valid_definition()
      }

      assert {:ok, projection} = RunbookContract.project(runbook, family)

      definition_bytes = byte_size(Jason.encode!(projection.definition))
      envelope_bytes = byte_size(Jason.encode!(projection)) - definition_bytes

      declared =
        RunbookContract.max_projection_bytes() -
          Runbooks.definition_limit!(:max_definition_bytes) -
          Runbooks.metadata_limit!(:title_bytes) -
          Runbooks.metadata_limit!(:description_bytes)

      assert envelope_bytes <= declared
    end
  end

  describe "summarize/3" do
    test "marks a projectable runbook available" do
      runbook = %Runbooks.Runbook{
        slug: "inspect-fleet",
        version: 3,
        title: "Inspect fleet",
        description: "Confirm the fleet is ready.",
        definition: valid_definition()
      }

      assert {:ok, summary} = RunbookContract.summarize(runbook, @family, "published")
      assert summary.available == true
      refute Map.has_key?(summary, :unavailable_reason)
      assert summary.runbook_ref == "inspect-fleet@3"
      assert summary.step_count == 1
    end

    test "keeps an oversized runbook listed and says where to open it" do
      runbook = oversized_runbook()

      assert {:ok, summary} = RunbookContract.summarize(runbook, @family, "published")
      assert summary.available == false
      assert summary.runbook_ref == "inspect-fleet@3"
      assert summary.step_count == 1
      assert summary.unavailable_reason =~ "over the #{RunbookContract.max_projection_bytes()}"
      assert summary.unavailable_reason =~ "console"
    end

    test "drops a runbook whose stored definition is not canonical" do
      runbook = %Runbooks.Runbook{
        slug: "legacy",
        version: 1,
        title: "Legacy",
        definition: %{"steps" => []}
      }

      assert RunbookContract.summarize(runbook, @family, "published") ==
               {:error, :incomplete_contract}
    end

    test "bounds the text summary in code points, the unit the wire schema counts" do
      # "e" + COMBINING ACUTE is one grapheme carrying two code points, so 600
      # graphemes are 1,200 code points. A grapheme-counted slice would have
      # returned 512 graphemes - 1,024 code points - past the schema's maxLength.
      combining = "e" <> <<0x0301::utf8>>

      runbook = %Runbooks.Runbook{
        slug: "inspect-fleet",
        version: 3,
        title: "Inspect fleet",
        description: String.duplicate(combining, 600),
        definition: valid_definition()
      }

      assert {:ok, summary} = RunbookContract.summarize(runbook, @family, "published")
      assert length(String.codepoints(summary.summary)) <= 512
    end
  end

  describe "project_draft/2" do
    test "adds the exact immutable draft and definition identities" do
      definition = valid_definition()

      runbook = %Runbooks.Runbook{
        id: Ecto.UUID.generate(),
        slug: "inspect-fleet",
        version: 4,
        title: "Inspect fleet",
        description: nil,
        definition: definition
      }

      assert {:ok, projection} = RunbookContract.project_draft(runbook, @family)
      assert projection.draft_id == runbook.id
      assert projection.family == @family
      assert projection.runbook_ref == "inspect-fleet@4"
      assert projection.status == "draft"
      assert projection.definition_sha256 == Runbooks.definition_digest(definition)
      assert projection.definition == definition
    end
  end

  # Larger than any changeset would now accept: the size guard is the backstop
  # for what the authoring byte bounds cannot catch, such as a description whose
  # JSON escaping expands it past its stored size.
  defp oversized_runbook do
    %Runbooks.Runbook{
      slug: "inspect-fleet",
      version: 3,
      title: "Inspect fleet",
      description: String.duplicate("a", RunbookContract.max_projection_bytes() + 1),
      definition: valid_definition()
    }
  end

  defp valid_definition do
    %{
      "schema_version" => 1,
      "context_markdown" => "Inspect before changing anything.",
      "inputs" => [
        %{
          "id" => "host",
          "description" => "Host to inspect",
          "type" => "string",
          "required" => true,
          "sensitive" => false
        }
      ],
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
              "args" => %{"host" => %{"source" => "input", "ref" => "host"}},
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
