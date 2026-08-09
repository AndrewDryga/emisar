defmodule EmisarWeb.MCP.RunbookContractTest do
  use ExUnit.Case, async: true
  alias Emisar.Runbooks
  alias EmisarWeb.MCP.RunbookContract

  describe "project/1" do
    test "keeps metadata separate and projects the canonical definition losslessly" do
      definition = valid_definition()

      runbook = %Runbooks.Runbook{
        slug: "inspect-fleet",
        live_version: 3,
        title: "Inspect fleet",
        description: "Confirm the fleet is ready.",
        definition: definition
      }

      assert {:ok, projection} = RunbookContract.project(runbook)

      assert projection == %{
               runbook_ref: "inspect-fleet@3",
               status: "published",
               definition_sha256: Runbooks.definition_digest(definition),
               title: "Inspect fleet",
               description: "Confirm the fleet is ready.",
               definition: definition,
               summary: %{input_count: 1, stage_count: 1, step_count: 1},
               draft_definition_sha256: nil
             }
    end

    test "names the unpublished change waiting behind the live release" do
      draft = valid_definition() |> Map.put("context_markdown", "Revised.")

      runbook = %Runbooks.Runbook{
        slug: "inspect-fleet",
        live_version: 3,
        title: "Inspect fleet",
        description: nil,
        definition: valid_definition(),
        draft_definition: draft
      }

      assert {:ok, projection} = RunbookContract.project(runbook)
      assert projection.draft_definition_sha256 == Runbooks.definition_digest(draft)
    end

    test "preserves nullable description" do
      runbook = %Runbooks.Runbook{
        slug: "inspect-fleet",
        live_version: 1,
        title: "Inspect fleet",
        description: nil,
        definition: valid_definition()
      }

      assert {:ok, %{description: nil}} = RunbookContract.project(runbook)
    end

    test "fails closed when the stored definition is not canonical" do
      runbook = %Runbooks.Runbook{
        slug: "legacy",
        live_version: 1,
        title: "Legacy",
        definition: %{"steps" => []}
      }

      assert RunbookContract.project(runbook) == {:error, :incomplete_contract}
    end

    test "reports an oversized runbook as oversized, not as a missing one" do
      runbook = oversized_runbook()

      assert {:error, {:runbook_too_large, bytes}} = RunbookContract.project(runbook)
      assert bytes > RunbookContract.max_projection_bytes()
    end

    test "the declared envelope covers every wrapper around the bounded values" do
      # The budget is definition + title + description + envelope, so the
      # envelope is the only term not pinned by an authoring limit. Measure it
      # at its worst case — longest ref, both digests present — so the
      # derivation cannot quietly drift under a growing projection.
      slug = String.duplicate("a", 79)

      runbook = %Runbooks.Runbook{
        slug: slug,
        live_version: 999_999_999,
        title: "",
        description: "",
        definition: valid_definition(),
        draft_definition: valid_definition()
      }

      assert {:ok, projection} = RunbookContract.project(runbook)

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

  describe "summarize/1" do
    test "names both sides of a live runbook carrying an unpublished change" do
      draft = valid_definition() |> Map.put("context_markdown", "Revised.")

      runbook = %Runbooks.Runbook{
        slug: "inspect-fleet",
        live_version: 3,
        title: "Inspect fleet",
        description: "Confirm the fleet is ready.",
        definition: valid_definition(),
        draft_definition: draft
      }

      assert {:ok, summary} = RunbookContract.summarize(runbook)

      assert summary == %{
               slug: "inspect-fleet",
               title: "Inspect fleet",
               summary: "Confirm the fleet is ready.",
               live: %{
                 runbook_ref: "inspect-fleet@3",
                 definition_sha256: Runbooks.definition_digest(valid_definition())
               },
               draft: %{definition_sha256: Runbooks.definition_digest(draft)},
               input_count: 1,
               stage_count: 1,
               step_count: 1,
               available: true
             }
    end

    test "counts a never-published runbook from its unpublished change" do
      runbook = %Runbooks.Runbook{
        slug: "inspect-fleet",
        title: "Inspect fleet",
        description: nil,
        draft_definition: valid_definition()
      }

      assert {:ok, summary} = RunbookContract.summarize(runbook)
      assert summary.live == nil
      assert summary.draft == %{definition_sha256: Runbooks.definition_digest(valid_definition())}
      assert summary.step_count == 1
      assert summary.available == true
    end

    test "keeps an oversized runbook listed and says where to open it" do
      runbook = oversized_runbook()

      assert {:ok, summary} = RunbookContract.summarize(runbook)
      assert summary.available == false
      assert summary.slug == "inspect-fleet"
      assert summary.step_count == 1
      assert summary.unavailable_reason =~ "over the #{RunbookContract.max_projection_bytes()}"
      assert summary.unavailable_reason =~ "console"
    end

    test "drops a runbook whose stored definition is not canonical" do
      runbook = %Runbooks.Runbook{
        slug: "legacy",
        live_version: 1,
        title: "Legacy",
        definition: %{"steps" => []}
      }

      assert RunbookContract.summarize(runbook) == {:error, :incomplete_contract}
    end

    test "bounds the text summary in code points, the unit the wire schema counts" do
      # "e" + COMBINING ACUTE is one grapheme carrying two code points, so 600
      # graphemes are 1,200 code points. A grapheme-counted slice would have
      # returned 512 graphemes - 1,024 code points - past the schema's maxLength.
      combining = "e" <> <<0x0301::utf8>>

      runbook = %Runbooks.Runbook{
        slug: "inspect-fleet",
        live_version: 3,
        title: "Inspect fleet",
        description: String.duplicate(combining, 600),
        definition: valid_definition()
      }

      assert {:ok, summary} = RunbookContract.summarize(runbook)
      assert length(String.codepoints(summary.summary)) <= 512
    end
  end

  describe "project_draft/1" do
    test "adds the draft's own identity and the release it does not replace yet" do
      definition = valid_definition()
      id = Ecto.UUID.generate()

      runbook = %Runbooks.Runbook{
        id: id,
        slug: "inspect-fleet",
        live_version: 4,
        title: "Inspect fleet",
        description: nil,
        definition: valid_definition(),
        draft_definition: definition
      }

      assert {:ok, projection} = RunbookContract.project_draft(runbook)

      assert projection == %{
               slug: "inspect-fleet",
               draft_id: id,
               status: "draft",
               definition_sha256: Runbooks.definition_digest(definition),
               title: "Inspect fleet",
               description: nil,
               definition: definition,
               summary: %{input_count: 1, stage_count: 1, step_count: 1},
               live_ref: "inspect-fleet@4"
             }
    end

    test "reports a null live ref while nothing has been published" do
      runbook = %Runbooks.Runbook{
        id: Ecto.UUID.generate(),
        slug: "inspect-fleet",
        title: "Inspect fleet",
        draft_definition: valid_definition()
      }

      assert {:ok, %{live_ref: nil}} = RunbookContract.project_draft(runbook)
    end
  end

  describe "live_ref/1" do
    test "names the live release and answers nil before the first publish" do
      assert RunbookContract.live_ref(%Runbooks.Runbook{slug: "inspect-fleet", live_version: 2}) ==
               "inspect-fleet@2"

      assert RunbookContract.live_ref(%Runbooks.Runbook{slug: "inspect-fleet"}) == nil
    end
  end

  # Larger than any changeset would now accept: the size guard is the backstop
  # for what the authoring byte bounds cannot catch, such as a description whose
  # JSON escaping expands it past its stored size.
  defp oversized_runbook do
    %Runbooks.Runbook{
      slug: "inspect-fleet",
      live_version: 3,
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
