defmodule Emisar.DescribeOwnershipTest do
  @moduledoc """
  One function, one test file.

  A `describe "fun/2"` block in two files means neither is the place to look:
  the giant `<context>_test.exs` and its focused sibling drift apart, each
  proving a subset, and a reader who finds one stops looking for the other.
  The four invitation describes had done exactly that — `accounts_test.exs`
  and `invitation_test.exs` both owned them, restating three tests between
  them in different words.

  The rule: the focused sibling owns the function; the context file keeps only
  what the sibling does not cover. This test fails when a new pair appears.
  `@known` is the state the 2026-09-11 tidy pass inherited — every entry is a
  pair still to be merged, not an exemption to copy. Shrink it; never add.
  """
  use ExUnit.Case, async: true

  # Same name, genuinely different module under test — not a collision.
  @coincidences ~w(
    parse/1 create/1 validate/1 validate/2 escape/1 all/0 execute/1 form/1
    digest/1 fetch/1 label/1 tarball_url/2
  )

  # Four more were merged in the same pass: the invitation functions
  # `invitation_test.exs` already owned, which `accounts_test.exs` restated.
  @known [
    "revoke_grant/2",
    "revoke_all_grants/1",
    "update_grant_lifetime_settings/3",
    "list_pending_approval_requests/2",
    "fetch_approval_request_by_id/3",
    "resolve_runbook_target_sets/2",
    "refs_outside_runner_access/2",
    "delete_inactive_runners/4",
    "list_retention_protected_pack_refs/3",
    "delete_pack/2",
    "delete_unseen_pack_versions/4",
    "delete_unadvertised_retired_pack_versions/2",
    "list_action_scope_pack_advertisements/1",
    "model_catalog/2",
    "sync_set_membership_authorization/4",
    "authenticate_scim_token/1",
    "scim_provision_user/2",
    "list_group_access/3",
    "cancel_run/3",
    "cancel_execution/2",
    "resolve_slug/2",
    "list_scoped_policy_summaries/2"
  ]

  test "no context function is described in two test files" do
    collisions =
      Path.wildcard(Path.join([__DIR__, "..", "**", "*_test.exs"]))
      |> Enum.flat_map(fn path ->
        path
        |> File.read!()
        |> then(&Regex.scan(~r/^  describe "([^"]+)" do$/m, &1, capture: :all_but_first))
        |> Enum.map(fn [name] -> {name, Path.relative_to(path, __DIR__)} end)
      end)
      |> Enum.group_by(fn {name, _path} -> name end, fn {_name, path} -> path end)
      |> Enum.filter(fn {name, paths} ->
        # A describe whose name is not a function reference (prose like
        # "bearer auth") says nothing about ownership.
        String.match?(name, ~r|^[a-z_]+[?!]?/\d$|) and
          name not in @coincidences and name not in @known and
          length(Enum.uniq(paths)) > 1
      end)
      |> Enum.map(fn {name, paths} -> "#{name}: #{Enum.join(Enum.uniq(paths), ", ")}" end)
      |> Enum.sort()

    assert collisions == [],
           """
           These functions are described in more than one test file. The focused
           sibling owns the function; the context file keeps only what the
           sibling does not cover.

           #{Enum.join(collisions, "\n")}
           """
  end
end
