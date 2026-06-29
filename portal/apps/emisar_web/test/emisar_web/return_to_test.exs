defmodule EmisarWeb.ReturnToTest do
  @moduledoc """
  The post-sign-in `return_to` whitelist. Load-bearing for the no-open-redirect
  property — every branded sign-in path (the magic-link request + confirm) runs
  attacker-influenceable input through here.
  """
  use ExUnit.Case, async: true
  alias EmisarWeb.ReturnTo

  test "accepts a bare local /app/<ref> target (slug or id)" do
    assert ReturnTo.app_path("/app/acme") == "/app/acme"
    assert ReturnTo.app_path("/app/019edfec-7ca9-784e-993f") == "/app/019edfec-7ca9-784e-993f"
  end

  test "rejects everything else" do
    # A trailing path — only the bare landing is honored.
    assert ReturnTo.app_path("/app/acme/runners") == nil
    # An absolute / off-site URL is never a local redirect.
    assert ReturnTo.app_path("https://evil.test/app/x") == nil
    assert ReturnTo.app_path("//evil.test") == nil
    # Not under /app.
    assert ReturnTo.app_path("/admin") == nil
    # Uppercase isn't in the slug charset, so it can't smuggle a path.
    assert ReturnTo.app_path("/app/Acme") == nil
    # Non-binaries.
    assert ReturnTo.app_path(nil) == nil
    assert ReturnTo.app_path(123) == nil
  end
end
