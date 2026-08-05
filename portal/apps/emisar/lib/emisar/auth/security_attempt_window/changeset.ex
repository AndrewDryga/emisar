defmodule Emisar.Auth.SecurityAttemptWindow.Changeset do
  use Emisar, :changeset
  alias Emisar.Auth.SecurityAttemptWindow

  def advance(%SecurityAttemptWindow{} = window, now, limit, window_ms)
      when is_integer(limit) and limit > 0 and is_integer(window_ms) and window_ms > 0 do
    cond do
      DateTime.compare(window.window_expires_at, now) != :gt ->
        {put_window(window, 1, now, window_ms), :allowed}

      window.attempt_count < limit ->
        {put_count(window, window.attempt_count + 1), :allowed}

      window.attempt_count == limit ->
        {put_count(window, limit + 1), :exhausted}

      true ->
        {change(window), :capped}
    end
  end

  defp put_window(window, count, now, window_ms) do
    window
    |> change(
      attempt_count: count,
      window_started_at: now,
      window_expires_at: DateTime.add(now, window_ms, :millisecond)
    )
    |> add_constraints()
  end

  defp put_count(window, count) do
    window
    |> change(attempt_count: count)
    |> add_constraints()
  end

  defp add_constraints(changeset) do
    changeset
    |> check_constraint(:scope, name: :auth_security_attempt_windows_scope_check)
    |> check_constraint(:attempt_count,
      name: :auth_security_attempt_windows_attempt_count_check
    )
    |> check_constraint(:window_expires_at,
      name: :auth_security_attempt_windows_window_check
    )
  end
end
