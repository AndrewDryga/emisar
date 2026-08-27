defmodule Emisar.SSO.OIDC.BoundedHTTPAdapter do
  @moduledoc """
  The oidcc HTTP transport with httpc's detached work disabled.

  httpc otherwise follows redirects and schedules Retry-After retries on its
  own; both can outlive oidcc's synchronous timeout, leaving a request to an
  untrusted IdP running after the caller already returned `:timeout`. This is
  the stock `:oidcc_http_adapter_httpc` delegation plus `autoredirect: false`
  and `autoretry: 0`, on the SSRF guard's httpc profile — the same two
  options the pre-3.8 dependency-source compile patch used to force before
  oidcc exposed this seam.
  """

  @behaviour :oidcc_http_adapter

  @impl :oidcc_http_adapter
  def request(method, request, http_options, request_options, config) do
    profile = Map.get(config, :profile, :default)

    :httpc.request(
      method,
      request,
      [{:autoredirect, false}, {:autoretry, 0} | http_options],
      request_options,
      profile
    )
  end
end
