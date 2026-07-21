defmodule EmisarWeb.DomainVerificationController do
  @moduledoc "Serves fixed public proof tokens for marketplace domain verification."
  use EmisarWeb, :controller

  @openai_apps_challenge "Akvd3R_a96uO5bgjAFCuvVd4rEZI7ZFPXLnLIRHEmpU"

  def openai_apps_challenge(conn, _params) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(:ok, @openai_apps_challenge)
  end
end
