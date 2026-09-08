defmodule Emisar.SSOGroupAccessTest do
  use Emisar.DataCase, async: true
  alias Emisar.{Accounts, Fixtures, SSO}
  alias Emisar.Accounts.RunnerAccess
  alias Emisar.SSO.{GroupAccess, GroupRunnerAccessMapping, IdentityProvider}

  @empty_selection %{
    "runner_access_mode" => "none",
    "scope" => [],
    "pack_access_mode" => "none",
    "pack_scope" => []
  }

  describe "group_access_defaults/1" do
    test "reads both persisted dimensions without granting omitted access" do
      assert SSO.group_access_defaults(%IdentityProvider{}) == RunnerAccess.none()

      assert SSO.group_access_defaults(%IdentityProvider{default_runner_access_mode: :all}) ==
               RunnerAccess.all()

      runner_id = Ecto.UUID.generate()

      provider = %IdentityProvider{
        default_runner_access_mode: :restricted,
        default_runner_scope_groups: ["database"],
        default_runner_scope_runner_ids: [runner_id],
        default_pack_access_mode: :restricted,
        default_pack_scope_pack_ids: ["postgres"]
      }

      assert {:ok, expected} =
               RunnerAccess.new(:restricted, ["database"], [runner_id], :restricted, ["postgres"])

      assert SSO.group_access_defaults(provider) == expected
    end
  end

  describe "group_access_selection/2" do
    test "combines inherited and explicit scopes once, independently for runners and packs" do
      {:ok, default} = RunnerAccess.new(:restricted, ["database"], [], :restricted, ["postgres"])

      selection =
        SSO.group_access_selection(default, %{
          "runner_access_mode" => "restricted",
          "scope" => ["group:database", "group:api"],
          "pack_access_mode" => "restricted",
          "pack_scope" => ["pack:postgres", "pack:shell"]
        })

      assert selection == %{
               "runner_access_mode" => "restricted",
               "scope" => ["group:database", "group:api"],
               "pack_access_mode" => "restricted",
               "pack_scope" => ["pack:postgres", "pack:shell"]
             }

      all = SSO.group_access_selection(RunnerAccess.all(), @empty_selection)
      assert all["runner_access_mode"] == "all"
      assert all["pack_access_mode"] == "all"
    end

    test "pack-only additions stay visible even without a current runner grant" do
      additions = %{
        @empty_selection
        | "pack_access_mode" => "restricted",
          "pack_scope" => ["pack:postgres"]
      }

      assert SSO.group_access_selection(RunnerAccess.none(), additions) == additions
    end
  end

  describe "group_access_additions/4" do
    test "never persists inherited groups, their runners or inherited packs as additions" do
      {:ok, default} = RunnerAccess.new(:restricted, ["database"], [], :restricted, ["postgres"])
      runner = %{id: Ecto.UUID.generate(), group: "database"}
      display = SSO.group_access_selection(default, @empty_selection)

      assert SSO.group_access_additions(default, %{}, display, [runner]) == @empty_selection

      additions =
        SSO.group_access_additions(
          default,
          %{
            "runner_access_mode" => "restricted",
            "scope" => ["group:database", "runner:#{runner.id}", "group:api"],
            "pack_access_mode" => "restricted",
            "pack_scope" => ["pack:postgres", "pack:shell"]
          },
          display,
          [runner]
        )

      assert additions == %{
               "runner_access_mode" => "restricted",
               "scope" => ["group:api"],
               "pack_access_mode" => "restricted",
               "pack_scope" => ["pack:shell"]
             }

      all = SSO.group_access_selection(RunnerAccess.all(), @empty_selection)
      assert SSO.group_access_additions(RunnerAccess.all(), %{}, all, []) == @empty_selection
    end

    test "omitted disabled pack controls preserve a pack-only grant until explicitly cleared" do
      for {mode, packs} <- [{"all", []}, {"restricted", ["pack:postgres"]}] do
        stored = %{@empty_selection | "pack_access_mode" => mode, "pack_scope" => packs}
        assert SSO.group_access_additions(RunnerAccess.none(), %{}, stored, []) == stored

        cleared =
          SSO.group_access_additions(
            RunnerAccess.none(),
            %{"pack_access_mode" => "none"},
            stored,
            []
          )

        assert SSO.empty_group_access?(cleared)
      end
    end
  end

  describe "empty_group_access?/1" do
    test "only both empty dimensions are removable; either independent half remains a grant" do
      assert SSO.empty_group_access?(@empty_selection)
      refute SSO.empty_group_access?(%{@empty_selection | "runner_access_mode" => "all"})
      refute SSO.empty_group_access?(%{@empty_selection | "pack_access_mode" => "all"})

      refute SSO.empty_group_access?(%{
               @empty_selection
               | "pack_access_mode" => "restricted",
                 "pack_scope" => ["pack:postgres"]
             })
    end
  end

  test "independent additions combine across groups with or without connection defaults" do
    {:ok, default} = RunnerAccess.new(:restricted, ["default"], [], :restricted, ["baseline"])

    runners = %GroupRunnerAccessMapping{
      runner_access_mode: :restricted,
      runner_scope_groups: ["extra"],
      pack_access_mode: :restricted,
      pack_scope_pack_ids: []
    }

    packs = %GroupRunnerAccessMapping{
      runner_access_mode: :none,
      pack_access_mode: :restricted,
      pack_scope_pack_ids: ["extra-pack"]
    }

    effective = GroupAccess.effective(default, [runners, packs])
    assert effective.groups == ["default", "extra"]
    assert effective.pack_ids == ["baseline", "extra-pack"]
    without_defaults = GroupAccess.effective(RunnerAccess.none(), [runners, packs])
    assert without_defaults.groups == ["extra"]
    assert without_defaults.pack_ids == ["extra-pack"]
    assert GroupAccess.effective(RunnerAccess.none(), [packs]) == RunnerAccess.none()
    no_packs = GroupAccess.effective(RunnerAccess.none(), [runners])
    assert no_packs.mode == :restricted
    refute RunnerAccess.pack_in_scope?("extra-pack", no_packs)
  end

  test "explicit no-packs is valid but an empty Selected packs input is still an error" do
    account_id = Ecto.UUID.generate()
    provider_id = Ecto.UUID.generate()
    group_id = Ecto.UUID.generate()
    attrs = %{directory_group_id: group_id, runner_access_mode: :all, pack_access_mode: :none}
    changeset = GroupRunnerAccessMapping.Changeset.form(account_id, provider_id, attrs)
    assert changeset.valid?
    assert Ecto.Changeset.get_field(changeset, :pack_access_mode) == :restricted
    assert Ecto.Changeset.get_field(changeset, :pack_scope_pack_ids) == []

    invalid =
      GroupRunnerAccessMapping.Changeset.form(account_id, provider_id, %{
        attrs
        | pack_access_mode: :restricted
      })

    refute invalid.valid?
    assert Keyword.has_key?(invalid.errors, :pack_access_mode)

    stored = Ecto.Changeset.apply_changes(changeset)

    updated =
      GroupRunnerAccessMapping.Changeset.update(stored, %{pack_scope: ["pack:postgres"]}, %{
        groups: [],
        runners: [],
        packs: ["postgres"]
      })

    assert updated.valid?
    assert Ecto.Changeset.get_field(updated, :pack_scope_pack_ids) == ["postgres"]
  end

  test "independent mappings persist and reconcile members; removal restores no-pack reach" do
    {_user, account, owner} = Fixtures.Subjects.owner_subject(%{plan: "enterprise"})

    provider =
      Fixtures.SSO.create_identity_provider(account_id: account.id, default_role: :operator)
      |> Fixtures.SSO.enable_scim()

    member = Fixtures.SSO.create_directory_member(provider)
    runner = Fixtures.Runners.create_runner(account_id: account.id, group: "database")

    {:ok, runner_group} =
      SSO.scim_upsert_group(
        provider,
        %{external_id: "runner-team", display: "Runner team", member_ids: [member.identity.id]}
      )

    {:ok, pack_group} =
      SSO.scim_upsert_group(
        provider,
        %{external_id: "pack-team", display: "Pack team", member_ids: [member.identity.id]}
      )

    assert {:ok, runner_mapping} =
             SSO.create_group_runner_access_mapping(
               provider,
               %{
                 directory_group_id: runner_group.id,
                 runner_access_mode: :restricted,
                 scope: ["runner:#{runner.id}"],
                 pack_access_mode: :none
               },
               owner
             )

    assert runner_mapping.pack_access_mode == :restricted
    assert runner_mapping.pack_scope_pack_ids == []
    access = Accounts.runner_access_for_membership(account.id, member.membership.id)
    assert access.runner_ids == [runner.id]
    refute RunnerAccess.pack_in_scope?("postgres", access)

    assert {:ok, pack_mapping} =
             SSO.create_group_runner_access_mapping(
               provider,
               %{
                 directory_group_id: pack_group.id,
                 runner_access_mode: :none,
                 pack_access_mode: :all
               },
               owner
             )

    assert pack_mapping.runner_scope_runner_ids == []
    access = Accounts.runner_access_for_membership(account.id, member.membership.id)
    assert access.runner_ids == [runner.id]
    assert access.pack_mode == :all
    assert {:ok, _} = SSO.delete_group_runner_access_mapping(pack_mapping, owner)
    access = Accounts.runner_access_for_membership(account.id, member.membership.id)
    assert access.runner_ids == [runner.id]
    refute RunnerAccess.pack_in_scope?("postgres", access)
  end

  test "half-grants retain permission, account isolation and both nondelegation dimensions" do
    {_user, account, owner} = Fixtures.Subjects.owner_subject(%{plan: "enterprise"})

    provider =
      Fixtures.SSO.create_identity_provider(account_id: account.id) |> Fixtures.SSO.enable_scim()

    group = Fixtures.SSO.create_directory_group(provider)

    viewer =
      Fixtures.Memberships.create_membership(account_id: account.id, role: "viewer")
      |> Fixtures.Subjects.membership_subject()

    attrs = %{directory_group_id: group.id, runner_access_mode: :none, pack_access_mode: :all}

    assert SSO.create_group_runner_access_mapping(provider, attrs, viewer) ==
             {:error, :unauthorized}

    {_other_user, _other_account, other} = Fixtures.Subjects.owner_subject(%{plan: "enterprise"})
    assert SSO.create_group_runner_access_mapping(provider, attrs, other) == {:error, :not_found}
    runner = Fixtures.Runners.create_runner(account_id: account.id, group: "database")
    admin = Fixtures.Memberships.create_membership(account_id: account.id, role: "admin")
    {:ok, limited} = RunnerAccess.new(:restricted, [], [runner.id])
    Fixtures.Memberships.force_runner_access(admin, limited)
    subject = Fixtures.Subjects.membership_subject(admin)

    assert SSO.create_group_runner_access_mapping(provider, attrs, subject) ==
             {:error, :runner_access_exceeds_subject}

    assert {:ok, group_rows, _} =
             SSO.list_group_access(provider, owner, page: [limit: 100])

    assert [] = Enum.flat_map(group_rows, &List.wrap(&1.runner_access_mapping))

    {:ok, pack_limited} = RunnerAccess.new(:all, [], [], :restricted, ["postgres"])
    Fixtures.Memberships.force_runner_access(admin, pack_limited)
    pack_subject = Fixtures.Subjects.membership_subject(admin)

    runner_only = %{
      directory_group_id: group.id,
      runner_access_mode: :all,
      pack_access_mode: :none
    }

    assert SSO.create_group_runner_access_mapping(provider, runner_only, pack_subject) ==
             {:error, :runner_access_exceeds_subject}

    assert {:ok, mapping} = SSO.create_group_runner_access_mapping(provider, runner_only, owner)

    assert SSO.update_group_runner_access_mapping(mapping, runner_only, pack_subject) ==
             {:error, :runner_access_exceeds_subject}

    assert Repo.reload!(mapping).pack_scope_pack_ids == []
  end
end
