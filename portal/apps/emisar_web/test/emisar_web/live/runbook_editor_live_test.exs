defmodule EmisarWeb.RunbookEditorLiveTest do
  use EmisarWeb.ConnCase, async: true

  describe "GET /app/runbooks/new" do
    test "renders the visual step builder", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
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

    test "step-card fields associate their label with the control via for/id", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runbooks/new")

      # The new editor renders one step (index 0); each labelled field carries a
      # matching label[for] + control[id] so the label is programmatically tied
      # to its input/select (screen readers, click-to-focus).
      for field <- ["id", "selector-kind", "selector-values"] do
        assert html =~ ~s(for="step-0-#{field}")
        assert html =~ ~s(id="step-0-#{field}")
      end
    end

    test "Action field renders before Step ID — picking action auto-derives id", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
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

    test "custom step id is preserved when action changes", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
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
      conn: conn
    } do
      {conn, _user, account} = register_and_log_in(conn)
      Emisar.Fixtures.runner_fixture(account_id: account.id, group: "edge-eu")
      Emisar.Fixtures.runner_fixture(account_id: account.id, group: "edge-us")

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

    test "the kind + targets selects reflect the picked values after a change", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      Emisar.Fixtures.runner_fixture(account_id: account.id, group: "edge-eu")
      Emisar.Fixtures.runner_fixture(account_id: account.id, group: "edge-us")

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

    test "a step with no target selected is flagged inline, not only at publish", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      Emisar.Fixtures.runner_fixture(account_id: account.id, group: "edge-eu")

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

  describe "metadata validation" do
    test "blank title shows an inline field error on save, not a flash", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/new")

      # Title starts blank; saving fails the changeset's title requirement. The
      # error renders inline under the Title input via <.error>…
      html = render_click(lv, "save", %{})
      assert html =~ "can&#39;t be blank" or html =~ "can't be blank"

      # …and the old humanized flash dump is gone.
      refute html =~ "Could not save runbook"

      # No runbook was persisted.
      assert Emisar.Repo.all(Emisar.Runbooks.Runbook) == []
    end

    test "an invalid slug shows an inline error live on change", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/new")

      # Slugs must start with a lowercase letter — an UPPERCASE value is
      # rejected and surfaces inline as the operator types, before any save.
      html =
        render_change(lv, "meta_change", %{"title" => "Repair", "slug" => "BAD SLUG"})

      assert html =~ "has invalid format"
      refute html =~ "Could not save runbook"
    end

    test "a fresh form paints no field error before any change/save", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runbooks/new")

      # Title is required + blank on a new form, but `<.input>` gates errors on
      # `used_input?` — an untouched field shows nothing until validate/save.
      refute html =~ "can&#39;t be blank"
      refute html =~ "can't be blank"
      refute html =~ "has invalid format"
    end

    test "a valid title + slug round-trips through meta_change with no error", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/new")

      html = render_change(lv, "meta_change", %{"title" => "Repair", "slug" => "rolling-repair"})

      # The typed values are reflected back into the inputs…
      assert html =~ ~s(value="Repair")
      assert html =~ ~s(value="rolling-repair")
      # …and a valid field shows no error even though the form has been validated.
      refute html =~ "has invalid format"
      refute html =~ "can&#39;t be blank"
      refute html =~ "can't be blank"
    end
  end

  describe "save / publish lifecycle" do
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

    test "save persists a draft and navigates to the index", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
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

    test "publish persists and marks the runbook published", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/new")

      fill_minimal_runbook(lv)
      render_click(lv, "publish", %{})
      assert_redirect(lv, ~p"/app/#{account}/runbooks")

      assert [%{status: :published}] = Emisar.Repo.all(Emisar.Runbooks.Runbook)
    end

    test "editing an existing runbook saves a NEW version, not an overwrite", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      subject = Emisar.Fixtures.subject_for(user, account)

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

    test "a viewer cannot save", %{conn: conn} do
      {_owner_conn, _owner, account} = register_and_log_in(conn)

      viewer = Emisar.Fixtures.user_fixture()

      _ =
        Emisar.Fixtures.membership_fixture(
          account_id: account.id,
          user_id: viewer.id,
          role: "viewer"
        )

      {:ok, lv, _html} =
        build_conn() |> log_in_user(viewer) |> live(~p"/app/#{account}/runbooks/new")

      assert render_click(lv, "save", %{}) =~ "You don&#39;t have permission to do that."
      assert Emisar.Repo.all(Emisar.Runbooks.Runbook) == []
    end
  end

  describe "per-step risk" do
    test "each step card shows its action's risk tier from the catalog", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      subject = Emisar.Fixtures.subject_for(user, account)
      runner = Emisar.Fixtures.runner_fixture(account_id: account.id)
      Emisar.Fixtures.action_fixture(runner: runner, action_id: "linux.uptime", risk: "high")

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
    test "remove, move, and arg add/remove reshape the step list", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/new")

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

    test "a crafted non-numeric index is a no-op, not a crash", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/new")

      before_html = render(lv)
      render_click(lv, "remove_step", %{"index" => "NaN"})
      render_click(lv, "move_step", %{"index" => "-1", "dir" => "up"})

      assert count_step_cards(render(lv)) == count_step_cards(before_html)
    end
  end

  defp count_step_cards(html) do
    html
    |> String.split("phx-change=\"step_change\"")
    |> length()
    |> Kernel.-(1)
  end
end
