defmodule EmisarWeb.RunbookEditorLiveTest do
  use EmisarWeb.ConnCase, async: true

  describe "GET /app/runbooks/new" do
    test "renders the visual step builder", %{conn: conn} do
      {conn, _user, _account} = register_and_log_in(conn)
      {:ok, lv, html} = live(conn, ~p"/app/runbooks/new")

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

    test "Action field renders before Step ID — picking action auto-derives id", %{conn: conn} do
      {conn, _user, _account} = register_and_log_in(conn)
      {:ok, lv, html} = live(conn, ~p"/app/runbooks/new")

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
      {conn, _user, _account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/runbooks/new")

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

      {:ok, lv, html} = live(conn, ~p"/app/runbooks/new")

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

      assert {:error, {:live_redirect, %{to: "/app/runbooks"}}} = render_click(lv, "save", %{})

      assert [runbook] = Emisar.Repo.all(Emisar.Runbooks.Runbook)
      step = hd(runbook.definition["steps"])
      assert step["runner_selector"] == %{"group" => ["edge-eu", "edge-us"]}
    end
  end

  describe "metadata validation" do
    test "blank title shows an inline field error on save, not a flash", %{conn: conn} do
      {conn, _user, _account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/runbooks/new")

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
      {conn, _user, _account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/runbooks/new")

      # Slugs must start with a lowercase letter — an UPPERCASE value is
      # rejected and surfaces inline as the operator types, before any save.
      html =
        render_change(lv, "meta_change", %{"title" => "Repair", "slug" => "BAD SLUG"})

      assert html =~ "has invalid format"
      refute html =~ "Could not save runbook"
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
      {conn, _user, _account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/runbooks/new")

      fill_minimal_runbook(lv)
      render_click(lv, "save", %{})
      assert_redirect(lv, "/app/runbooks")

      assert [runbook] = Emisar.Repo.all(Emisar.Runbooks.Runbook)
      assert runbook.title == "Disk triage"
      assert runbook.status == :draft
      assert runbook.slug == "disk-triage"

      assert [%{"id" => "check_disk", "action_id" => "linux.df"} | _] =
               runbook.definition["steps"]
    end

    test "publish persists and marks the runbook published", %{conn: conn} do
      {conn, _user, _account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/runbooks/new")

      fill_minimal_runbook(lv)
      render_click(lv, "publish", %{})
      assert_redirect(lv, "/app/runbooks")

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

      {:ok, lv, html} = live(conn, ~p"/app/runbooks/#{original.id}/edit")
      assert html =~ "Patch night"

      render_change(lv, "meta_change", %{"title" => "Patch night v2", "slug" => "patch-night"})
      render_click(lv, "save", %{})
      assert_redirect(lv, "/app/runbooks")

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

      {:ok, lv, _html} = build_conn() |> log_in_user(viewer) |> live(~p"/app/runbooks/new")

      assert render_click(lv, "save", %{}) =~ "You don&#39;t have permission to do that."
      assert Emisar.Repo.all(Emisar.Runbooks.Runbook) == []
    end
  end

  describe "step manipulation" do
    test "remove, move, and arg add/remove reshape the step list", %{conn: conn} do
      {conn, _user, _account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/runbooks/new")

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
      {conn, _user, _account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/runbooks/new")

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
