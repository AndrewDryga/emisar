defmodule EmisarWeb.RunbookEditorLiveTest do
  use EmisarWeb.ConnCase, async: true

  describe "GET /app/runbooks/new" do
    setup %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      %{conn: conn, account: account}
    end

    test "renders the visual step builder", %{conn: conn, account: account} do
      {:ok, lv, html} = live(conn, ~p"/app/#{account}/runbooks/new")

      # Top-level shape: step list with add button. Each step is an
      # action dispatch — the assert step type used to exist in the UI
      # but had no backing executor and was ripped out.
      assert html =~ "Steps"
      assert html =~ "Add step"
      refute html =~ "Assert"
      refute html =~ "steps_json"

      # Adding a step inserts another card.
      before_count = count_step_cards(render(lv))
      render_click(lv, "add_action_step", %{})
      after_count = count_step_cards(render(lv))
      assert after_count == before_count + 1
    end

    test "step-card fields associate their label with the control via for/id", %{
      conn: conn,
      account: account
    } do
      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runbooks/new")

      # The new editor renders one step (index 0); each labelled field carries a
      # matching label[for] + control[id] so the label is programmatically tied
      # to its input/select (screen readers, click-to-focus).
      for field <- ["id", "selector-kind", "selector-values"] do
        assert html =~ ~s(for="step-0-#{field}")
        assert html =~ ~s(id="step-0-#{field}")
      end
    end

    test "Action field renders before Step ID — picking action auto-derives id", %{
      conn: conn,
      account: account
    } do
      {:ok, lv, html} = live(conn, ~p"/app/#{account}/runbooks/new")

      # In the rendered step card, the Action <input name="action_id">
      # must come BEFORE the Step ID <input name="step_id"> so the form
      # asks "what does this step do?" before "what should we call it?".
      action_pos = :binary.match(html, "name=\"action_id\"") |> elem(0)
      step_pos = :binary.match(html, "name=\"step_id\"") |> elem(0)
      assert action_pos < step_pos, "Action field should render above Step ID"

      # Default step id is auto-generated as step<digits>. Picking an
      # action should swap that placeholder for a slug derived from the
      # action id. Custom-typed ids are preserved (covered separately).
      render_change(lv, "step_change", %{
        "index" => "0",
        "step_id" => "step123",
        "action_id" => "linux.uptime",
        "selector_kind" => "group",
        "selector_values" => ["linux"]
      })

      html2 = render(lv)
      assert html2 =~ "linux_uptime"
      refute html2 =~ ~s(value="step123")
    end

    test "custom step id is preserved when action changes", %{conn: conn, account: account} do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/new")

      # Operator types a custom id first.
      render_change(lv, "step_change", %{
        "index" => "0",
        "step_id" => "disk_check",
        "action_id" => "",
        "selector_kind" => "group",
        "selector_values" => []
      })

      # Then picks an action — id should NOT be overwritten.
      render_change(lv, "step_change", %{
        "index" => "0",
        "step_id" => "disk_check",
        "action_id" => "linux.df",
        "selector_kind" => "group",
        "selector_values" => ["linux"]
      })

      html = render(lv)
      assert html =~ ~s(value="disk_check")
      refute html =~ ~s(value="linux_df")
    end

    test "runner targets are a multi-select of the account's groups, saved as a list", %{
      conn: conn,
      account: account
    } do
      Fixtures.Runners.create_runner(account_id: account.id, group: "edge-eu")
      Fixtures.Runners.create_runner(account_id: account.id, group: "edge-us")

      {:ok, lv, html} = live(conn, ~p"/app/#{account}/runbooks/new")

      # The target picker is a <select multiple> listing the account's groups,
      # not a free-text input.
      assert html =~ ~s(name="selector_values[]")
      assert html =~ "multiple"
      assert html =~ "edge-eu"
      assert html =~ "edge-us"

      render_change(lv, "meta_change", %{"title" => "Fleet check"})

      render_change(lv, "step_change", %{
        "index" => "0",
        "step_id" => "check",
        "action_id" => "linux.uptime",
        "selector_kind" => "group",
        "selector_values" => ["edge-eu", "edge-us"]
      })

      dest = ~p"/app/#{account}/runbooks"
      assert {:error, {:live_redirect, %{to: ^dest}}} = render_click(lv, "save", %{})

      assert [runbook] = Emisar.Repo.all(Emisar.Runbooks.Runbook)
      step = hd(runbook.definition["steps"])
      assert step["runner_selector"] == %{"group" => ["edge-eu", "edge-us"]}
    end

    test "the kind + targets selects reflect the picked values after a change", %{
      conn: conn,
      account: account
    } do
      Fixtures.Runners.create_runner(account_id: account.id, group: "edge-eu")
      Fixtures.Runners.create_runner(account_id: account.id, group: "edge-us")

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/new")

      html =
        render_change(lv, "step_change", %{
          "index" => "0",
          "step_id" => "check",
          "action_id" => "linux.uptime",
          "selector_kind" => "group",
          "selector_values" => ["edge-eu"]
        })

      # selector_kind (a plain single-value <.input type="select">) marks the
      # current kind selected; selector_values (the multi-select <.select>)
      # marks the picked group selected and leaves the unpicked one alone.
      assert html =~ ~r/<option(?=[^>]*\bvalue="group")(?=[^>]*\bselected)[^>]*>/
      assert html =~ ~r/<option(?=[^>]*\bvalue="edge-eu")(?=[^>]*\bselected)[^>]*>/
      refute html =~ ~r/<option(?=[^>]*\bvalue="edge-us")(?=[^>]*\bselected)[^>]*>/
    end

    test "a step with no target selected is flagged inline, not only at publish", %{
      conn: conn,
      account: account
    } do
      Fixtures.Runners.create_runner(account_id: account.id, group: "edge-eu")

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/new")

      # A step targeting groups but with nothing picked → inline marker shows
      # (mirrors the run view), instead of staying silent until publish.
      html =
        render_change(lv, "step_change", %{
          "index" => "0",
          "step_id" => "check",
          "action_id" => "linux.uptime",
          "selector_kind" => "group",
          "selector_values" => []
        })

      assert html =~ "No target set"

      # Pick a target → the marker clears.
      html =
        render_change(lv, "step_change", %{
          "index" => "0",
          "step_id" => "check",
          "action_id" => "linux.uptime",
          "selector_kind" => "group",
          "selector_values" => ["edge-eu"]
        })

      refute html =~ "No target set"
    end
  end

  describe "GET /app/runbooks/:id/edit (open by id)" do
    setup %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      %{conn: conn, account: account}
    end

    test "a non-existent (well-formed) id flashes not-found and redirects to the library", %{
      conn: conn,
      account: account
    } do
      missing = Emisar.Repo.generate_id()
      to = ~p"/app/#{account}/runbooks"

      assert {:error, {:live_redirect, %{to: ^to, flash: flash}}} =
               live(conn, ~p"/app/#{account}/runbooks/#{missing}/edit")

      assert flash["error"] =~ "not found"
    end

    test "a garbage (non-uuid) id flashes not-found and redirects to the library", %{
      conn: conn,
      account: account
    } do
      to = ~p"/app/#{account}/runbooks"

      assert {:error, {:live_redirect, %{to: ^to, flash: flash}}} =
               live(conn, ~p"/app/#{account}/runbooks/not-a-uuid/edit")

      assert flash["error"] =~ "not found"
    end
  end

  describe "metadata validation" do
    setup %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, lv, html} = live(conn, ~p"/app/#{account}/runbooks/new")
      %{conn: conn, account: account, lv: lv, html: html}
    end

    test "blank title shows an inline field error on save, not a flash", %{lv: lv} do
      # Title starts blank; saving fails the changeset's title requirement. The
      # error renders inline under the Title input via <.error>…
      html = render_click(lv, "save", %{})
      assert html =~ "can&#39;t be blank" or html =~ "can't be blank"

      # …and the old humanized flash dump is gone.
      refute html =~ "Could not save runbook"

      # No runbook was persisted.
      assert Emisar.Repo.all(Emisar.Runbooks.Runbook) == []
    end

    test "an invalid slug shows an inline error live on change", %{lv: lv} do
      # Slugs must start with a lowercase letter — an UPPERCASE value is
      # rejected and surfaces inline as the operator types, before any save.
      html =
        render_change(lv, "meta_change", %{"title" => "Repair", "slug" => "BAD SLUG"})

      assert html =~ "has invalid format"
      refute html =~ "Could not save runbook"
    end

    test "a fresh form paints no field error before any change/save", %{html: html} do
      # Title is required + blank on a new form, but `<.input>` gates errors on
      # `used_input?` — an untouched field shows nothing until validate/save.
      refute html =~ "can&#39;t be blank"
      refute html =~ "can't be blank"
      refute html =~ "has invalid format"
    end

    test "a valid title + slug round-trips through meta_change with no error", %{lv: lv} do
      html = render_change(lv, "meta_change", %{"title" => "Repair", "slug" => "rolling-repair"})

      # The typed values are reflected back into the inputs…
      assert html =~ ~s(value="Repair")
      assert html =~ ~s(value="rolling-repair")
      # …and a valid field shows no error even though the form has been validated.
      refute html =~ "has invalid format"
      refute html =~ "can&#39;t be blank"
      refute html =~ "can't be blank"
    end

    test "an 81-character title is rejected inline (length 1–80)", %{lv: lv} do
      # The form changeset bounds the title to 80 chars — an 81-char one surfaces
      # the length violation inline on the Title field once validate runs (no flash).
      html = render_change(lv, "meta_change", %{"title" => String.duplicate("a", 81)})

      assert html =~ "should be at most 80 character(s)"
      refute html =~ "Could not save runbook"
    end
  end

  describe "save / publish lifecycle" do
    setup %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      %{conn: conn, user: user, account: account}
    end

    defp fill_minimal_runbook(lv) do
      render_change(lv, "meta_change", %{"title" => "Disk triage", "slug" => ""})

      render_change(lv, "step_change", %{
        "index" => "0",
        "step_id" => "check_disk",
        "action_id" => "linux.df",
        "selector_kind" => "group",
        "selector_values" => ["linux"]
      })
    end

    test "save persists a draft and navigates to the index", %{conn: conn, account: account} do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/new")

      fill_minimal_runbook(lv)
      render_click(lv, "save", %{})
      assert_redirect(lv, ~p"/app/#{account}/runbooks")

      assert [runbook] = Emisar.Repo.all(Emisar.Runbooks.Runbook)
      assert runbook.title == "Disk triage"
      assert runbook.status == :draft
      assert runbook.slug == "disk-triage"

      assert [%{"id" => "check_disk", "action_id" => "linux.df"} | _] =
               runbook.definition["steps"]
    end

    test "publish persists and marks the runbook published", %{conn: conn, account: account} do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/new")

      fill_minimal_runbook(lv)
      render_click(lv, "publish", %{})
      assert_redirect(lv, ~p"/app/#{account}/runbooks")

      assert [%{status: :published}] = Emisar.Repo.all(Emisar.Runbooks.Runbook)
    end

    test "editing an existing runbook saves a NEW version, not an overwrite", %{
      conn: conn,
      user: user,
      account: account
    } do
      subject = Fixtures.Subjects.subject_for(user, account)

      {:ok, original} =
        Emisar.Runbooks.create_runbook(
          %{
            "title" => "Patch night",
            "name" => "Patch night",
            "slug" => "patch-night",
            "definition" => %{
              "steps" => [%{"id" => "s1", "action_id" => "linux.uptime", "args" => %{}}]
            }
          },
          subject
        )

      {:ok, lv, html} = live(conn, ~p"/app/#{account}/runbooks/#{original.id}/edit")
      assert html =~ "Patch night"

      render_change(lv, "meta_change", %{"title" => "Patch night v2", "slug" => "patch-night"})
      render_click(lv, "save", %{})
      assert_redirect(lv, ~p"/app/#{account}/runbooks")

      runbooks = Emisar.Repo.all(Emisar.Runbooks.Runbook)
      assert length(runbooks) == 2
      assert Enum.max_by(runbooks, & &1.version).title == "Patch night v2"
    end

    test "a viewer cannot save", %{account: account} do
      viewer = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: viewer.id,
          role: "viewer"
        )

      {:ok, lv, _html} =
        build_conn() |> log_in_user(viewer) |> live(~p"/app/#{account}/runbooks/new")

      assert render_click(lv, "save", %{}) =~ "You don&#39;t have permission to do that."
      assert Emisar.Repo.all(Emisar.Runbooks.Runbook) == []
    end

    test "a structural definition error surfaces on the Steps panel, not as a flash", %{
      conn: conn,
      account: account
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/new")

      render_change(lv, "meta_change", %{"title" => "Too many targets", "slug" => ""})

      # A step targeting 51 groups blows the changeset's per-step selector cap
      # (max 50) — a `:definition` error with no metadata input to bind to. It
      # must surface as one concise line on the Steps panel via
      # save_error_message/1 (a rose callout), not a top flash.
      targets = for n <- 1..51, do: "group#{n}"

      render_change(lv, "step_change", %{
        "index" => "0",
        "step_id" => "fanout",
        "action_id" => "linux.uptime",
        "selector_kind" => "group",
        "selector_values" => targets
      })

      html = render_click(lv, "save", %{})

      assert html =~ "Steps: a step targets too many runners or groups (max 50)"
      # Not a flash banner — the structural error lives on the Steps panel.
      refute html =~ ~s(id="flash-error")
      # Nothing persisted — the bound definition was rejected.
      assert Emisar.Repo.all(Emisar.Runbooks.Runbook) == []
    end

    test "the success flash names the new version saved", %{
      conn: conn,
      user: user,
      account: account
    } do
      subject = Fixtures.Subjects.subject_for(user, account)

      {:ok, v1} =
        Emisar.Runbooks.create_runbook(
          %{
            "title" => "Patch night",
            "name" => "Patch night",
            "slug" => "patch-night",
            "definition" => %{"steps" => [%{"id" => "s1", "action_id" => "linux.uptime"}]}
          },
          subject
        )

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/#{v1.id}/edit")

      render_change(lv, "meta_change", %{"title" => "Patch night v2", "slug" => "patch-night"})
      render_click(lv, "save", %{})

      # Saving an existing runbook bumps to v2 — the flash names that version so
      # the operator knows a NEW draft version was created, not an overwrite.
      flash = assert_redirect(lv, ~p"/app/#{account}/runbooks")
      assert flash["info"] == "Draft v2 saved."
    end

    test "editing a published runbook shows the immutability note in the version aside", %{
      conn: conn,
      user: user,
      account: account
    } do
      subject = Fixtures.Subjects.subject_for(user, account)

      {:ok, published} =
        Emisar.Runbooks.create_runbook(
          %{
            "title" => "Locked",
            "name" => "Locked",
            "slug" => "locked",
            "definition" => %{
              "steps" => [
                %{
                  "id" => "s1",
                  "action_id" => "linux.uptime",
                  "runner_selector" => %{"group" => ["prod"]}
                }
              ]
            }
          },
          subject
        )

      {:ok, published} = Emisar.Runbooks.publish(published, subject)

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runbooks/#{published.id}/edit")

      # The Version aside states the copy-on-write model + that saving creates
      # the next version — so the author isn't surprised the published row is left
      # intact.
      assert html =~ "Published runbooks are immutable — saving creates a new draft version."
      assert html =~ "v#{published.version + 1}"
    end

    test "there is no unpublish — a published runbook offers only save/publish", %{
      conn: conn,
      user: user,
      account: account
    } do
      subject = Fixtures.Subjects.subject_for(user, account)

      {:ok, published} =
        Emisar.Runbooks.create_runbook(
          %{
            "title" => "No unpublish",
            "name" => "No unpublish",
            "slug" => "no-unpublish",
            "definition" => %{
              "steps" => [
                %{
                  "id" => "s1",
                  "action_id" => "linux.uptime",
                  "runner_selector" => %{"group" => ["prod"]}
                }
              ]
            }
          },
          subject
        )

      {:ok, published} = Emisar.Runbooks.publish(published, subject)

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runbooks/#{published.id}/edit")

      # Revising a published runbook is "save a new draft version", never an
      # unpublish: the editor exposes Save draft + Publish and no unpublish
      # control or handler.
      refute html =~ "Unpublish"
      refute html =~ ~s(phx-click="unpublish")
      assert html =~ "Save draft"
      assert html =~ "Publish"
    end
  end

  describe "per-step risk" do
    test "each step card shows its action's risk tier from the catalog", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      subject = Fixtures.Subjects.subject_for(user, account)
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime", risk: "high")

      {:ok, runbook} =
        Emisar.Runbooks.create_runbook(
          %{
            "title" => "Patch night",
            "name" => "Patch night",
            "slug" => "patch-night",
            "definition" => %{
              "steps" => [%{"id" => "s1", "action_id" => "linux.uptime", "args" => %{}}]
            }
          },
          subject
        )

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runbooks/#{runbook.id}/edit")

      # The step's action is high-risk in the catalog → the card shows the
      # rose risk pill, so the author sees the tier they're composing.
      assert html =~ "high"
      assert html =~ "ring-rose-500/30"
    end
  end

  describe "step manipulation" do
    setup %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/new")
      %{conn: conn, account: account, lv: lv}
    end

    test "remove, move, and arg add/remove reshape the step list", %{lv: lv} do
      # Two steps: give them distinct ids, then move step 1 up.
      render_change(lv, "step_change", %{
        "index" => "0",
        "step_id" => "first",
        "action_id" => "",
        "selector_kind" => "group",
        "selector_values" => []
      })

      render_click(lv, "add_action_step", %{})

      render_change(lv, "step_change", %{
        "index" => "1",
        "step_id" => "second",
        "action_id" => "",
        "selector_kind" => "group",
        "selector_values" => []
      })

      html = render_click(lv, "move_step", %{"index" => "1", "dir" => "up"})
      first_pos = :binary.match(html, ~s(value="second")) |> elem(0)
      second_pos = :binary.match(html, ~s(value="first")) |> elem(0)
      assert first_pos < second_pos

      # Args: add one to the (now first) step, then remove it.
      html = render_click(lv, "add_arg", %{"index" => "0"})
      assert html =~ "arg_change"

      html = render_click(lv, "remove_arg", %{"index" => "0", "arg" => "0"})
      refute html =~ "arg_change"

      # Remove a step entirely.
      before_count = count_step_cards(render(lv))
      render_click(lv, "remove_step", %{"index" => "1"})
      assert count_step_cards(render(lv)) == before_count - 1
    end

    test "a crafted non-numeric index is a no-op, not a crash", %{lv: lv} do
      before_html = render(lv)
      render_click(lv, "remove_step", %{"index" => "NaN"})
      render_click(lv, "move_step", %{"index" => "-1", "dir" => "up"})

      assert count_step_cards(render(lv)) == count_step_cards(before_html)
    end
  end

  describe "add a step (RBK-011)" do
    setup %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/new")
      %{conn: conn, account: account, lv: lv}
    end

    test "add appends a BLANK card with an auto-derivable placeholder id", %{lv: lv} do
      before_count = count_step_cards(render(lv))
      html = render_click(lv, "add_action_step", %{})
      assert count_step_cards(html) == before_count + 1

      # The newly appended card is empty: no action, no selected target, no args.
      assert html =~ ~s(name="action_id" value="" )
      # The "No args." resting line proves the new card carries an empty arg list.
      assert html =~ "No args."

      # Its id is the `step<digits>` placeholder example_action_step/0 emits, so
      # RBK-015's auto-derive treats it as not-yet-customized.
      assert [_ | _] = step_id_values(html)
      assert Enum.all?(step_id_values(html), &(&1 =~ ~r/^step\d+$/))
    end

    test "two added steps never collide on id", %{lv: lv} do
      render_click(lv, "add_action_step", %{})
      html = render_click(lv, "add_action_step", %{})

      ids = step_id_values(html)
      # The seeded step + two added → three placeholder ids, all distinct
      # (each from a fresh System.unique_integer([:positive])).
      assert length(ids) == 3
      assert ids == Enum.uniq(ids)
    end

    test "a blank added step saves as a draft (completeness deferred to publish)", %{
      account: account,
      lv: lv
    } do
      # Title is required for any save; the steps stay blank (seeded + added).
      render_change(lv, "meta_change", %{"title" => "Draft with blanks", "slug" => ""})
      render_click(lv, "add_action_step", %{})

      render_click(lv, "save", %{})
      assert_redirect(lv, ~p"/app/#{account}/runbooks")

      assert [runbook] = Emisar.Repo.all(Emisar.Runbooks.Runbook)
      assert runbook.status == :draft
      # Both blank steps persisted — only publish enforces a complete definition.
      assert length(runbook.definition["steps"]) == 2
    end

    test "adding from an empty list replaces the empty-state", %{lv: lv} do
      # Drop the single seeded step → the Steps panel shows its empty-state.
      empty = render_click(lv, "remove_step", %{"index" => "0"})
      assert count_step_cards(empty) == 0
      assert empty =~ "No steps. Add an action step above to start."

      # Adding one brings the first card back and clears the empty-state line.
      filled = render_click(lv, "add_action_step", %{})
      assert count_step_cards(filled) == 1
      refute filled =~ "No steps. Add an action step above to start."
    end
  end

  describe "remove a step (RBK-012)" do
    setup %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, lv, html} = live(conn, ~p"/app/#{account}/runbooks/new")
      %{conn: conn, account: account, lv: lv, html: html}
    end

    test "the trash button carries a confirm", %{html: html} do
      assert html =~ ~s(data-confirm="Remove this step?")
    end

    test "removing the only step returns the empty-state", %{lv: lv} do
      # A fresh :new editor seeds exactly one step; removing it leaves none.
      html = render_click(lv, "remove_step", %{"index" => "0"})
      assert count_step_cards(html) == 0
      assert html =~ "No steps. Add an action step above to start."
    end
  end

  describe "reorder a step (RBK-013)" do
    setup %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, lv, html} = live(conn, ~p"/app/#{account}/runbooks/new")
      %{conn: conn, account: account, lv: lv, html: html}
    end

    test "move-up at the first / move-down at the last are no-ops with the end buttons disabled",
         %{lv: lv} do
      # Give the seeded step a stable id, then add a second so first/last differ.
      render_change(lv, "step_change", %{
        "index" => "0",
        "step_id" => "first",
        "action_id" => "",
        "selector_kind" => "group",
        "selector_values" => []
      })

      render_click(lv, "add_action_step", %{})

      render_change(lv, "step_change", %{
        "index" => "1",
        "step_id" => "second",
        "action_id" => "",
        "selector_kind" => "group",
        "selector_values" => []
      })

      before_html = render(lv)
      before_order = step_id_values(before_html)

      # Move-up on the first step and move-down on the last both target an
      # out-of-range index → the order is unchanged.
      render_click(lv, "move_step", %{"index" => "0", "dir" => "up"})
      render_click(lv, "move_step", %{"index" => "1", "dir" => "down"})
      assert step_id_values(render(lv)) == before_order

      # The end buttons are also rendered `disabled`: up on the first card,
      # down on the last card.
      assert before_html =~
               ~r/<button(?=[^>]*phx-value-dir="up")(?=[^>]*phx-value-index="0")(?=[^>]*\bdisabled)[^>]*>/

      assert before_html =~
               ~r/<button(?=[^>]*phx-value-dir="down")(?=[^>]*phx-value-index="1")(?=[^>]*\bdisabled)[^>]*>/
    end

    test "a single-step list disables both move buttons", %{html: html} do
      # The lone seeded step is both first (index 0) and last (total-1), so
      # its up AND down buttons are disabled.
      assert html =~
               ~r/<button(?=[^>]*phx-value-dir="up")(?=[^>]*phx-value-index="0")(?=[^>]*\bdisabled)[^>]*>/

      assert html =~
               ~r/<button(?=[^>]*phx-value-dir="down")(?=[^>]*phx-value-index="0")(?=[^>]*\bdisabled)[^>]*>/
    end
  end

  describe "edit a step's action (RBK-014)" do
    setup %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      %{conn: conn, user: user, account: account}
    end

    test "the action datalist lists the COMPLETE catalog with no truncation", %{
      conn: conn,
      user: user,
      account: account
    } do
      subject = Fixtures.Subjects.subject_for(user, account)
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      # Advertise > 35 actions; the picker must offer every one (the same
      # complete set MCP reads), never a paginated page.
      action_ids = for n <- 1..40, do: "pack.action_#{String.pad_leading("#{n}", 3, "0")}"

      for action_id <- action_ids do
        Fixtures.Catalog.create_action(runner: runner, action_id: action_id)
      end

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runbooks/new")
      assert is_struct(subject, Emisar.Auth.Subject)

      datalist = extract_datalist(html, "catalog-actions")

      for action_id <- action_ids do
        assert datalist =~ ~s(value="#{action_id}")
      end
    end

    test "an uncataloged typed action shows no risk pill", %{
      conn: conn,
      user: user,
      account: account
    } do
      subject = Fixtures.Subjects.subject_for(user, account)
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      # A high-risk action IS cataloged, so a rose pill is what shows when it's
      # the chosen action — proving the absence below is the unknown-action path.
      Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime", risk: "high")
      assert is_struct(subject, Emisar.Auth.Subject)

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/new")

      # Type an action no runner advertises → @risk_by_action miss → @risk nil →
      # the `:if={@risk}` risk pill never renders (no rose/amber/brand ring).
      html =
        render_change(lv, "step_change", %{
          "index" => "0",
          "step_id" => "mystery",
          "action_id" => "totally.unknown_action",
          "selector_kind" => "group",
          "selector_values" => []
        })

      refute html =~ "ring-rose-500/30"
      refute html =~ "ring-amber-500/30"
      refute html =~ "ring-brand-500/30"
    end

    test "a blank/unknown action is allowed in a draft save", %{conn: conn, account: account} do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/new")

      render_change(lv, "meta_change", %{"title" => "Blank action", "slug" => ""})

      # Leave the seeded step's action blank, give it a target, Save draft.
      render_change(lv, "step_change", %{
        "index" => "0",
        "step_id" => "noop",
        "action_id" => "",
        "selector_kind" => "group",
        "selector_values" => ["linux"]
      })

      render_click(lv, "save", %{})
      assert_redirect(lv, ~p"/app/#{account}/runbooks")

      assert [runbook] = Emisar.Repo.all(Emisar.Runbooks.Runbook)
      assert runbook.status == :draft
      assert [%{"action_id" => ""} | _] = runbook.definition["steps"]
    end
  end

  describe "edit a step's id (RBK-015)" do
    setup %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/new")
      %{conn: conn, account: account, lv: lv}
    end

    test "a blank action does not auto-derive the step id", %{lv: lv} do
      # Placeholder id is still in place, but the auto-derive guard requires a
      # non-blank action_id — with a blank action the placeholder must stand.
      [seeded_id] = step_id_values(render(lv))

      html =
        render_change(lv, "step_change", %{
          "index" => "0",
          "step_id" => seeded_id,
          "action_id" => "",
          "selector_kind" => "group",
          "selector_values" => []
        })

      assert step_id_values(html) == [seeded_id]
    end

    test "the auto-derived step id is capped at 40 chars", %{lv: lv} do
      [seeded_id] = step_id_values(render(lv))

      # A very long action id (non-alnum → "_") derives a step id sliced to 40.
      long_action = "pack." <> String.duplicate("very_long_segment.", 6)

      html =
        render_change(lv, "step_change", %{
          "index" => "0",
          "step_id" => seeded_id,
          "action_id" => long_action,
          "selector_kind" => "group",
          "selector_values" => []
        })

      [derived] = step_id_values(html)
      assert String.length(derived) == 40
    end

    test "typing `step5` is treated as not-customized and still auto-derives", %{lv: lv} do
      # `step5` matches the `^step\d+$` placeholder regex, so picking an action
      # overwrites it (acceptable — it reads like an auto id, not a deliberate name).
      html =
        render_change(lv, "step_change", %{
          "index" => "0",
          "step_id" => "step5",
          "action_id" => "linux.df",
          "selector_kind" => "group",
          "selector_values" => []
        })

      assert step_id_values(html) == ["linux_df"]
    end

    test "the step_id form key remaps to the canonical id key", %{account: account, lv: lv} do
      render_change(lv, "meta_change", %{"title" => "Remap", "slug" => ""})

      # The form posts `step_id` (to avoid clashing with the HTML element id);
      # step_change must store it under the canonical "id" key the engine reads.
      render_change(lv, "step_change", %{
        "index" => "0",
        "step_id" => "custom_id",
        "action_id" => "linux.df",
        "selector_kind" => "group",
        "selector_values" => ["linux"]
      })

      render_click(lv, "save", %{})
      assert_redirect(lv, ~p"/app/#{account}/runbooks")

      assert [runbook] = Emisar.Repo.all(Emisar.Runbooks.Runbook)
      assert [%{"id" => "custom_id"} | _] = runbook.definition["steps"]
    end
  end

  describe "edit a step's args (RBK-016)" do
    setup %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      %{conn: conn, user: user, account: account}
    end

    test "per-action arg suggestions render in a datalist", %{
      conn: conn,
      user: user,
      account: account
    } do
      subject = Fixtures.Subjects.subject_for(user, account)
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      # The action advertises two args → the editor builds a per-action datalist
      # (`args-{action}`) listing the union of advertised arg names.
      Fixtures.Catalog.create_action(
        runner: runner,
        action_id: "linux.tail",
        args_schema: %{"args" => [%{"name" => "path"}, %{"name" => "lines"}]}
      )

      assert is_struct(subject, Emisar.Auth.Subject)

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runbooks/new")

      datalist = extract_datalist(html, "args-linux_tail")
      assert datalist =~ ~s(value="path")
      assert datalist =~ ~s(value="lines")
    end

    test "an action with no advertised args hides the \"Known for\" hint", %{
      conn: conn,
      user: user,
      account: account
    } do
      subject = Fixtures.Subjects.subject_for(user, account)
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      # linux.uptime is cataloged but advertises NO args (the default empty
      # args_schema) → its args_by_action entry is [], so the arg editor's
      # `:if={@known_args != []}` "Known for …" hint must not render.
      Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime")
      assert is_struct(subject, Emisar.Auth.Subject)

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/new")

      html =
        render_change(lv, "step_change", %{
          "index" => "0",
          "step_id" => "check",
          "action_id" => "linux.uptime",
          "selector_kind" => "group",
          "selector_values" => []
        })

      # The Args section still renders (label + the "No args." resting line), but
      # the per-action suggestion hint is absent — there's nothing to suggest.
      assert html =~ "No args."
      refute html =~ "Known for"
    end

    test "step add/remove are socket-only — nothing persists, no audit row, until Save", %{
      conn: conn,
      user: user,
      account: account
    } do
      subject = Fixtures.Subjects.subject_for(user, account)

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/new")

      # Reshape the step list in the socket (add two, remove one) without ever
      # clicking Save. All step state is socket-only until Save flattens it, so the
      # DB must stay empty and no runbook.created audit row may be written.
      render_click(lv, "add_action_step", %{})
      render_click(lv, "add_action_step", %{})
      render_click(lv, "remove_step", %{"index" => "0"})

      assert Emisar.Repo.all(Emisar.Runbooks.Runbook) == []

      {:ok, events, _} = Emisar.Audit.list_events(subject, page: [limit: 20])
      refute Enum.any?(events, &(&1.event_type == "runbook.created"))
    end

    test "blank arg-key pairs are dropped on flatten; values are stored as strings", %{
      conn: conn,
      account: account
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/new")

      render_change(lv, "meta_change", %{"title" => "Arg flatten", "slug" => ""})

      render_change(lv, "step_change", %{
        "index" => "0",
        "step_id" => "tail",
        "action_id" => "linux.tail",
        "selector_kind" => "group",
        "selector_values" => ["linux"]
      })

      # One real pair (numeric-looking value) + one blank-key pair.
      render_click(lv, "add_arg", %{"index" => "0"})
      render_click(lv, "add_arg", %{"index" => "0"})

      render_change(lv, "arg_change", %{
        "index" => "0",
        "arg" => "0",
        "key" => "lines",
        "value" => "200"
      })

      render_change(lv, "arg_change", %{
        "index" => "0",
        "arg" => "1",
        "key" => "",
        "value" => "orphaned"
      })

      render_click(lv, "save", %{})
      assert_redirect(lv, ~p"/app/#{account}/runbooks")

      assert [runbook] = Emisar.Repo.all(Emisar.Runbooks.Runbook)
      [step] = runbook.definition["steps"]

      # The blank-key pair is gone; the kept value persists as a STRING (the
      # runner is responsible for any type coercion).
      assert step["args"] == %{"lines" => "200"}
    end
  end

  describe "set a step's target (RBK-017)" do
    setup %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      %{conn: conn, account: account}
    end

    test "a kind switch clears stale selected values", %{conn: conn, account: account} do
      Fixtures.Runners.create_runner(account_id: account.id, group: "edge-eu")

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/new")

      # Pick a group target…
      render_change(lv, "step_change", %{
        "index" => "0",
        "step_id" => "check",
        "action_id" => "linux.uptime",
        "selector_kind" => "group",
        "selector_values" => ["edge-eu"]
      })

      # …then switch the kind to runner_id WITHOUT re-posting values. The old
      # group value no longer applies to the runner option set, so it's dropped
      # → the step is back to "no target set".
      html =
        render_change(lv, "step_change", %{
          "index" => "0",
          "step_id" => "check",
          "action_id" => "linux.uptime",
          "selector_kind" => "runner_id",
          "selector_values" => ["edge-eu"]
        })

      refute html =~ ~r/<option(?=[^>]*\bvalue="edge-eu")(?=[^>]*\bselected)[^>]*>/
    end

    test "an empty multi-select posts nothing and defaults values to []", %{
      conn: conn,
      account: account
    } do
      Fixtures.Runners.create_runner(account_id: account.id, group: "edge-eu")

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/new")
      render_change(lv, "meta_change", %{"title" => "No target", "slug" => ""})

      # Select a target, then a change that omits `selector_values` entirely
      # (what a deselected <select multiple> posts) must reset it to [].
      render_change(lv, "step_change", %{
        "index" => "0",
        "step_id" => "check",
        "action_id" => "linux.uptime",
        "selector_kind" => "group",
        "selector_values" => ["edge-eu"]
      })

      html =
        render_change(lv, "step_change", %{
          "index" => "0",
          "step_id" => "check",
          "action_id" => "linux.uptime",
          "selector_kind" => "group"
        })

      assert html =~ "No target set"

      render_click(lv, "save", %{})
      assert_redirect(lv, ~p"/app/#{account}/runbooks")

      assert [runbook] = Emisar.Repo.all(Emisar.Runbooks.Runbook)
      [step] = runbook.definition["steps"]
      assert step["runner_selector"] == %{"group" => []}
    end

    test "no runners/groups yet → the picker shows guidance", %{conn: conn, account: account} do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/new")

      # Default kind is "group" and the account has none yet.
      assert render(lv) =~ "No runner groups yet."

      # Switch to runner_id with no runners → the runner-specific guidance shows.
      html =
        render_change(lv, "step_change", %{
          "index" => "0",
          "step_id" => "check",
          "action_id" => "linux.uptime",
          "selector_kind" => "runner_id",
          "selector_values" => []
        })

      assert html =~ "No runners connected yet."
    end

    test "a selected-but-now-absent target is preserved in the options", %{
      conn: conn,
      account: account
    } do
      Fixtures.Runners.create_runner(account_id: account.id, group: "edge-eu")

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/new")
      render_change(lv, "meta_change", %{"title" => "Ghost target", "slug" => ""})

      # Select a group that the live set does NOT contain (e.g. a group whose
      # runners all disconnected). selector_options/4 keeps it so the next save
      # doesn't silently drop the operator's selection.
      html =
        render_change(lv, "step_change", %{
          "index" => "0",
          "step_id" => "check",
          "action_id" => "linux.uptime",
          "selector_kind" => "group",
          "selector_values" => ["ghost-group"]
        })

      assert html =~ ~r/<option(?=[^>]*\bvalue="ghost-group")(?=[^>]*\bselected)[^>]*>/

      render_click(lv, "save", %{})
      assert_redirect(lv, ~p"/app/#{account}/runbooks")

      assert [runbook] = Emisar.Repo.all(Emisar.Runbooks.Runbook)
      [step] = runbook.definition["steps"]
      assert step["runner_selector"] == %{"group" => ["ghost-group"]}
    end
  end

  describe "edit metadata (RBK-018)" do
    setup %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, lv, html} = live(conn, ~p"/app/#{account}/runbooks/new")
      %{conn: conn, account: account, lv: lv, html: html}
    end

    test "a blank slug surfaces no slug error (nilified for auto-derive)", %{lv: lv} do
      # A valid title with a blank slug must not raise a format error — the
      # changeset nilifies the empty slug; Save derives it from the title.
      html = render_change(lv, "meta_change", %{"title" => "Rolling repair", "slug" => ""})

      refute html =~ "has invalid format"
      refute html =~ "can&#39;t be blank"
      refute html =~ "can't be blank"
    end

    test "the metadata form posts FLAT keys, not runbook[...] keys", %{html: html} do
      # Each metadata <.input> carries an explicit flat name + id so meta_change
      # reads top-level "title"/"slug"/"description" (no `runbook[title]` nesting).
      assert html =~ ~s(name="title")
      assert html =~ ~s(name="slug")
      assert html =~ ~s(name="description")
      assert html =~ ~s(id="runbook_title")
      refute html =~ ~s(name="runbook[title]")
    end

    test "the metadata changeset never validates the step definition", %{lv: lv} do
      # The step in socket state is blank (no action, no target) — a definition
      # changeset would reject it — but the form-only changeset casts just
      # title/slug/description, so meta_change surfaces no Steps error.
      html = render_change(lv, "meta_change", %{"title" => "Form only", "slug" => "form-only"})

      refute html =~ "Steps:"
      refute html =~ "has invalid format"
      refute html =~ "can&#39;t be blank"
      refute html =~ "can't be blank"
    end
  end

  # The value of every Step ID <input name="step_id">, in render order. The
  # rendered input carries `id=` between `name=` and `value=`, so skip it.
  defp step_id_values(html) do
    ~r/name="step_id"[^>]*?\bvalue="([^"]*)"/
    |> Regex.scan(html)
    |> Enum.map(fn [_, value] -> value end)
  end

  # The `<datalist id="...">…</datalist>` fragment, so an option assertion can't
  # accidentally match an identically-valued <option> elsewhere on the page.
  defp extract_datalist(html, id) do
    [_, body] = Regex.run(~r/<datalist id="#{id}">(.*?)<\/datalist>/s, html)
    body
  end

  defp count_step_cards(html) do
    html
    |> String.split("phx-change=\"step_change\"")
    |> length()
    |> Kernel.-(1)
  end
end
