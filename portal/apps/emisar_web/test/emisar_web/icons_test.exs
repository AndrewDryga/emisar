defmodule EmisarWeb.IconsTest do
  @moduledoc """
  The registry's mechanical contract. Metaphor, optical alignment, and family
  coherence are review judgments made against rendered pixels
  (`.agent/kb/rules/design-semantic-icon-system.md`); what a test can decide is
  that every meaning exists exactly once, every master parses, and nothing here
  depends on colour to stay whole.
  """
  use ExUnit.Case, async: true
  alias EmisarWeb.Icons

  @masters Path.wildcard(Path.join([__DIR__, "..", "..", "priv", "icons", "*", "*.svg"]))

  describe "master/2" do
    test "a size at or below 16px takes the compact master where one exists" do
      assert Icons.master("action.retry", 16) != Icons.master("action.retry", 24)
      assert Icons.master("action.retry", 14) == Icons.master("action.retry", 16)
      assert Icons.master("action.retry", 20) == Icons.master("action.retry", 24)
    end

    test "a meaning with no compact master keeps its regular one at every size" do
      assert Icons.master("action.clear_filters", 16) == Icons.master("action.clear_filters", 48)
    end

    test "a compact master earns its place by differing from the regular one" do
      # It is an optical correction for the 16px raster, not a second icon. One
      # that renders identically is a file the registry would read forever to
      # produce the pixels the regular master already produces.
      for token <- Icons.compact_tokens() do
        assert Icons.master(token, 16) != Icons.master(token, 24),
               "#{token}'s compact master is identical to its regular one"
      end
    end

    test "an unknown meaning raises with the closest registered ones" do
      assert_raise ArgumentError, ~r/unknown icon "product\.runnr".*"product\.runner"/s, fn ->
        Icons.master("product.runnr", 24)
      end
    end

    test "a master renders as safe markup, so no template reaches for raw/1" do
      assert {:safe, body} = Icons.master("product.runner", 24)
      assert body =~ "<path"
    end
  end

  describe "grid/1" do
    test "reports the bucket whose stroke weight suits the output size" do
      assert Icons.grid(12) == 16
      assert Icons.grid(16) == 16
      assert Icons.grid(20) == 20
      assert Icons.grid(24) == 24
      assert Icons.grid(48) == 24
    end
  end

  describe "the master files" do
    test "every meaning is namespaced and owned by exactly one regular master" do
      assert Icons.tokens() == Enum.uniq(Icons.tokens())

      for token <- Icons.tokens() do
        assert [_namespace, _name] = String.split(token, ".")
        assert Icons.token?(token)
      end
    end

    test "a compact master belongs to a meaning that has a regular one" do
      assert Icons.compact_tokens() -- Icons.tokens() == []
    end

    test "every master is one XML-valid document on a system grid" do
      # A regular master lives on the shared 24 grid; a compact may instead be
      # a native 16-grid cut that renders 1:1 for pixel-crisp small sizes.
      for path <- @masters do
        source = File.read!(path)

        if String.ends_with?(path, ".16.svg") do
          assert source =~ ~r/viewBox="0 0 (?:16 16|24 24)"/, "#{path} leaves the system grids"
        else
          assert source =~ ~s(viewBox="0 0 24 24"), "#{path} leaves the shared grid"
        end

        assert {{:xmlElement, :svg, _, _, _, _, _, _, _, _, _, _}, ~c""} =
                 :xmerl_scan.string(String.to_charlist(source), quiet: true),
               "#{path} is not one valid <svg> document"
      end
    end

    test "a semantic class marks emphasis and never carries the whole drawing" do
      # Emphasis is a PART of a drawing. A master made entirely of accented
      # parts has no anatomy left in `currentColor`, so it can no longer take
      # its call site's colour — which is how the free plan's deliberately muted
      # checks came out brand emerald beside the paid plan's.
      shapes = ~r/<(?:path|circle|rect|ellipse|line|polygon|polyline)\b[^>]*>/

      for path <- @masters do
        drawing = String.replace(File.read!(path), ~r/<defs>[\s\S]*?<\/defs>/, "")
        elements = Regex.scan(shapes, drawing) |> List.flatten()

        assert Enum.any?(elements, &(not (&1 =~ ~r/class="[^"]*\b(?:accent|warn|danger)\b/))),
               "#{path} paints entirely in one semantic class — that is its anatomy, not emphasis"
      end
    end

    test "a mask id is content-addressed, so repeated instances cannot collide" do
      ids =
        for path <- @masters,
            [id, body] <-
              Regex.scan(~r/<mask id="([^"]+)"[^>]*>([\s\S]*?)<\/mask>/, File.read!(path),
                capture: :all_but_first
              ),
            do: {id, body}

      refute ids == []

      for {id, body} <- ids do
        digest = body |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
        assert id == "emisar-icon-" <> String.slice(digest, 0, 10)
      end
    end

    test "every mask a master references is defined once, for the page to share" do
      {:safe, defs} = Icons.mask_defs()

      referenced =
        for token <- Icons.tokens(),
            size <- [16, 24],
            {:safe, body} = Icons.master(token, size),
            [id] <- Regex.scan(~r/mask="url\(#([^)]+)\)"/, body, capture: :all_but_first),
            do: id

      refute referenced == []

      for id <- Enum.uniq(referenced) do
        assert defs =~ ~s(<mask id="#{id}"), "#{id} is referenced but never defined"
        assert length(Regex.scan(~r/<mask id="#{id}"/, defs)) == 1
      end

      # A dangling reference renders as nothing, so the shared defs may not
      # carry anything an icon does not actually reach for either.
      for [id] <- Regex.scan(~r/<mask id="([^"]+)"/, defs, capture: :all_but_first) do
        assert id in referenced, "#{id} is defined but no master references it"
      end
    end

    test "a master states no colour of its own outside a mask" do
      # Anatomy paints in `currentColor` and emphasis goes through the semantic
      # classes, so an icon takes the colour of the surface it lands on — a
      # technology mark included: the founder tried the official Kubernetes ink
      # in the docs list and reversed it the same day, because trademark colour
      # inside first-party chrome reads as a foreign accent. Only a mask names
      # literal black and white, and those are its luminance, not ink.
      for path <- @masters do
        without_masks = String.replace(File.read!(path), ~r/<mask[\s\S]*?<\/mask>/, "")

        refute without_masks =~ ~r/(?:fill|stroke)="#/, "#{path} hardcodes a colour"
      end
    end

    test "a generated 16-grid cut keeps every coordinate on the quarter grid" do
      # The half grid carries the 1px crispness; dots and radii use quarters.
      # A drifting coordinate means the cutter regressed or someone edited a
      # generated file by hand — hand-tuned cuts declare `data-hand-cut` and
      # are judged visually instead.
      for path <- @masters,
          String.ends_with?(path, ".16.svg"),
          source = File.read!(path),
          source =~ ~s(viewBox="0 0 16 16"),
          not (source =~ "data-hand-cut") do
        numbers =
          Regex.scan(~r/(?:\bd|\bc?[xy]\d?|\br[xy]?|\bwidth|\bheight)="([^"]+)"/, source,
            capture: :all_but_first
          )
          |> List.flatten()
          |> Enum.flat_map(&Regex.scan(~r/-?\d*\.?\d+/, &1))
          |> List.flatten()

        for number <- numbers do
          value = number |> Float.parse() |> elem(0)

          assert Float.round(value * 4) == value * 4,
                 "#{path} has off-grid coordinate #{number}"
        end
      end
    end

    test "sibling families share their noun's exact construction at 16px" do
      # The family contract in pixels: every badge is the same ring, every
      # document the same sheet, every shield the same shield — differing only
      # in modifier. A family member drifting to its own outline reads as
      # sloppy even when no single icon is wrong.
      families = [
        {~s(<circle cx="8" cy="8" r="6.5"),
         ~w(state.success state.error state.denied state.info state.pending
            state.disabled state.update_available
            story.eliminated docs.upgrade action.cancel)},
        {~s(M3.5 2H9.5L12.5 5V14H3.5ZM9.5 2V5H12.5),
         ~w(evidence.document evidence.verified_document product.policy trust.declared)}
      ]

      for {construction, tokens} <- families, token <- tokens do
        {:safe, body} = Icons.master(token, 16)

        assert body =~ construction,
               "#{token} drifted off its family construction"
      end
    end

    test "meanings that deliberately share a drawing stay byte-identical" do
      # A universal symbol may serve one concept across namespaces (the rule's
      # own precedent: action.next and diagram.flow_right share the arrow). The
      # registry has no alias — a shared drawing is two files — so nothing but
      # this test stops one copy from being redrawn alone. That already happened:
      # the affirm check drifted half a unit apart at 16px while the 24px pair
      # still matched, so the ledger's check and a plan-feature check were two
      # drawings of one meaning.
      shared = [
        {"action.approve", "state.included"},
        {"action.next", "diagram.flow_right"},
        {"action.move_down", "diagram.flow_down"},
        {"action.remove", "state.not_included"},
        {"docs.upgrade", "state.update_available"},
        {"story.dispatch", "trust.signed_dispatch"}
      ]

      for {left, right} <- shared, size <- [16, 24] do
        assert Icons.master(left, size) == Icons.master(right, size),
               "#{left} and #{right} share a meaning but drew apart at #{size}px"
      end
    end

    test "the locked brand and vendor artwork stays out of the registry" do
      # The gate mark and the official identity-provider marks are brand assets
      # with their own components; a semantic namespace would invite a redraw.
      for token <- Icons.tokens() do
        refute String.starts_with?(token, "brand.")
        refute String.starts_with?(token, "vendor.")
      end
    end
  end
end
