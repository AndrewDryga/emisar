defmodule EmisarWeb.AuthComponents do
  @moduledoc """
  The sign-in, registration and MFA chrome — the centred card layout, the
  one-time-code input, and the enrollment steps.

  Split out of CoreComponents. These render only on the unauthenticated auth
  pages and the profile MFA flow.
  """
  use Phoenix.Component
  use Gettext, backend: EmisarWeb.Gettext

  use Phoenix.VerifiedRoutes,
    endpoint: EmisarWeb.Endpoint,
    router: EmisarWeb.Router,
    statics: EmisarWeb.static_paths()

  import EmisarWeb.CoreComponents
  import EmisarWeb.MarketingComponents, only: [brand: 1]

  @doc """
  iPhone-style one-box-per-character code entry, driven by the `CodeInput` JS
  hook. The boxes are client-owned and aggregate into a hidden `name` field the
  form submits, so the group carries `phx-update="ignore"` — a LiveView
  re-render (a flash, an expiry countdown) can't wipe what was typed. `numeric`
  switches the filter + `inputmode` to digits-only (TOTP, email step-up); the
  default is the alphanumeric sign-in-code alphabet. An `error` renders inline
  below the boxes (outside the ignored group, so it updates) — a rejected code
  is shown right at the input, never as a far-off flash.
  """
  attr :id, :string, required: true
  attr :name, :string, required: true, doc: "the hidden field the aggregate posts as"
  attr :label, :string, required: true
  attr :length, :integer, default: 6
  attr :numeric, :boolean, default: false
  attr :error, :string, default: nil, doc: "a validation error, rendered inline below the boxes"

  def code_input(assigns) do
    ~H"""
    <div>
      <div id={@id} phx-hook="CodeInput" phx-update="ignore" data-numeric={to_string(@numeric)}>
        <.label for={"#{@id}-1"}>{@label}</.label>
        <div class="mt-2 flex justify-between gap-2 sm:gap-2.5">
          <input
            :for={i <- 1..@length}
            id={"#{@id}-#{i}"}
            data-box
            type="text"
            inputmode={if @numeric, do: "numeric", else: "text"}
            autocapitalize={if @numeric, do: "off", else: "characters"}
            autocomplete={i == 1 && "one-time-code"}
            maxlength="1"
            aria-label={"Character #{i} of #{@length}"}
            class={[
              "h-14 w-full min-w-0 rounded-lg border border-zinc-700 bg-zinc-950 text-center",
              "text-xl font-semibold tracking-widest text-zinc-100 shadow-sm outline-none transition",
              "focus:border-brand-500 focus:ring-2 focus:ring-brand-500/30",
              not @numeric && "uppercase"
            ]}
          />
        </div>
        <input type="hidden" name={@name} data-code />
      </div>
      <.error :if={@error}>{@error}</.error>
    </div>
    """
  end

  @doc """
  Two-column auth-flow layout: marketing copy on the left, form on the
  right. Used by sign in / sign up / magic link / password reset.
  """
  attr :title, :string, required: true
  slot :inner_block, required: true

  def auth_layout(assigns) do
    ~H"""
    <div class="grid min-h-screen grid-cols-1 lg:grid-cols-2">
      <div class="hidden bg-gradient-to-br from-brand-950 via-zinc-950 to-zinc-950 p-12 lg:flex lg:flex-col">
        <a href="/" class="text-zinc-100">
          <.brand size={:md} />
        </a>

        <div class="flex flex-1 items-center">
          <div class="max-w-md">
            <p class="text-2xl font-semibold leading-snug tracking-tight text-zinc-100">
              Your agent keeps working in production — inside bounds you set.
            </p>
            <ul class="mt-6 space-y-3 text-sm text-zinc-400">
              <li class="flex items-start gap-2.5">
                <.icon name="hero-check" class="mt-0.5 h-4 w-4 flex-none text-brand-400" />
                <span>Declared actions and runbooks instead of arbitrary shell</span>
              </li>
              <li class="flex items-start gap-2.5">
                <.icon name="hero-check" class="mt-0.5 h-4 w-4 flex-none text-brand-400" />
                <span>Policy decides per action: allowed, denied, or held for approval</span>
              </li>
              <li class="flex items-start gap-2.5">
                <.icon name="hero-check" class="mt-0.5 h-4 w-4 flex-none text-brand-400" />
                <span>
                  Searchable audit of every action and decision, plus a hash-chained host journal
                </span>
              </li>
            </ul>
          </div>
        </div>

        <%!-- Invisible mirror of the logo row above, so the pitch's flex-1
             centering area is vertically symmetric and its optical center
             matches the form column's (which hides its logo at lg). --%>
        <div class="invisible" aria-hidden="true">
          <.brand size={:md} />
        </div>
      </div>

      <div class="flex flex-col p-6 lg:p-12">
        <.link href={~p"/"} class="mb-10 inline-block lg:hidden">
          <.brand size={:md} />
        </.link>

        <%!-- Mobile anchors to a consistent top (centering short content
             leaves a floating dead-zone that varies per sibling page);
             lg keeps the vertical centering. --%>
        <div class="flex flex-1 items-start justify-center pt-2 lg:items-center lg:pt-0">
          <div class="w-full max-w-md">
            <h1 class="text-3xl font-bold tracking-tight text-zinc-50">{@title}</h1>
            <div class="mt-8">
              {render_slot(@inner_block)}
            </div>
          </div>
        </div>

        <div class="flex justify-center">
          <footer class="mt-10 w-full max-w-md border-t border-zinc-800/70 pt-6">
            <nav class="flex flex-wrap items-center gap-x-4 gap-y-1 text-xs text-zinc-400">
              <.link href={~p"/trust"} class="transition-colors hover:text-zinc-300">Trust</.link>
              <.link href={~p"/privacy"} class="transition-colors hover:text-zinc-300">Privacy</.link>
              <.link href={~p"/terms"} class="transition-colors hover:text-zinc-300">Terms</.link>
              <.link href={~p"/security"} class="transition-colors hover:text-zinc-300">
                Security
              </.link>
            </nav>
            <p class="mt-3 text-xs text-zinc-400">
              © {Date.utc_today().year} Andrii Dryga. All rights reserved.
            </p>
          </footer>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  The auth pages' footer switch-line — one muted centered paragraph with a
  brand link ("New to emisar? Create an account"). One shape for the whole
  auth family (design-console-ux §3; the hand-rolled copies drifted mt-6/mt-8 and
  dropped classes). The lead-in rides the `:lead` slot, the link label is the
  default slot, and exactly one of `navigate`/`href` picks the link mode.

      <.auth_footer_link href={~p"/sign_up"}>
        <:lead>New to emisar?</:lead>
        Create an account
      </.auth_footer_link>
  """
  attr :navigate, :string, default: nil
  attr :href, :string, default: nil
  slot :lead, doc: "the muted lead-in text before the link"
  slot :inner_block, required: true

  def auth_footer_link(assigns) do
    ~H"""
    <p class="mt-6 text-center text-sm text-zinc-400">
      {render_slot(@lead)}
      <.link
        navigate={@navigate}
        href={@href}
        class="font-medium text-brand-400 hover:text-brand-300"
      >
        {render_slot(@inner_block)}
      </.link>
    </p>
    """
  end

  @doc """
  A horizontal rule with a centered label ("or") — separates the primary
  sign-in method from the alternatives so the auth pages read as one path with
  fallbacks, not a wall of equal options. The label background matches the
  auth-page surface (zinc-950) so the rule appears to pass behind it.

      <.or_separator />
      <.or_separator label="or with email" />
  """
  attr :label, :string, default: "or"
  attr :class, :string, default: nil

  def or_separator(assigns) do
    ~H"""
    <div class={["relative my-6", @class]}>
      <div class="absolute inset-0 flex items-center" aria-hidden="true">
        <div class="w-full border-t border-zinc-800/70"></div>
      </div>
      <div class="relative flex justify-center">
        <span class="bg-zinc-950 px-3 text-xs lowercase text-zinc-500">{@label}</span>
      </div>
    </div>
    """
  end

  # -- Generic page primitives ---------------------------------------

  # `.card`/`.panel` are GONE (§8.1 content-on-canvas): every console surface
  # is a naked `<section>` + `<.section_header>`; boxes are earned by secrets
  # (`secret_reveal`), code artifacts (`code_panel`), or actionable warnings
  # (`callout`). The stat tile below keeps the one sanctioned island surface
  # inline (the dashboard pillar grammar).

  @doc """
  The centered auth/consent card — the focused, chrome-less decision surface
  shared by the OAuth consent screen and the device-grant approval page: a
  full-viewport centered column, the emisar logo, and ONE rounded card. The
  card's sections are the caller's content; `:footer` renders in the bordered
  bottom band (the "Signed in as …" line).

      <.auth_card>
        <div class="border-b border-zinc-800 px-6 py-5">…header…</div>
        <div class="px-6 py-5">…body…</div>
        <:footer>Signed in as {@current_user.email}</:footer>
      </.auth_card>
  """
  slot :inner_block, required: true
  slot :footer

  def auth_card(assigns) do
    ~H"""
    <div class="flex min-h-screen items-center justify-center bg-zinc-950 px-6 py-12">
      <div class="w-full max-w-md">
        <div class="mb-8 flex justify-center">
          <img src={~p"/images/brand/emisar-logo.svg"} alt="emisar" class="h-8 w-auto" />
        </div>

        <div class="overflow-hidden rounded-2xl border border-zinc-800 bg-zinc-900/60 shadow-xl">
          {render_slot(@inner_block)}
          <div :if={@footer != []} class="border-t border-zinc-800 px-6 py-3">
            <p class="text-center text-xs text-zinc-500">{render_slot(@footer)}</p>
          </div>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  The quiet reassurance/caution band inside an auth card — the bordered black
  note under a consent's scope list ("policy still applies", "only approve a
  request you started yourself").
  """
  attr :class, :string, default: nil
  slot :inner_block, required: true

  def consent_note(assigns) do
    ~H"""
    <div class={["rounded-lg border border-zinc-800 bg-black/40 px-4 py-3", @class]}>
      <p class="text-xs leading-relaxed text-zinc-500">{render_slot(@inner_block)}</p>
    </div>
    """
  end

  @doc """
  Current-inbox proof step shared by voluntary and enforced MFA enrollment.
  It deliberately precedes the authenticator secret: a stolen session cannot
  add its own factor before proving control of the user's current email.
  """
  attr :email, :string, required: true
  attr :form, Phoenix.HTML.Form, required: true
  attr :error, :string, default: nil
  slot :actions, required: true

  def mfa_enrollment_email_verification(assigns) do
    ~H"""
    <div class="space-y-4">
      <p class="text-sm text-zinc-300">
        We sent a 6-digit code to <span class="font-medium text-zinc-100">{@email}</span>.
        Enter it before adding an authenticator.
      </p>
      <.simple_form
        for={@form}
        id="mfa_enrollment_email_form"
        phx-submit="verify_mfa_enrollment_email"
      >
        <.code_input
          id="mfa-enrollment-email-code"
          name="mfa_enrollment[code]"
          numeric
          label="Email verification code"
          error={@error}
        />
        <:actions>
          {render_slot(@actions)}
        </:actions>
      </.simple_form>
    </div>
    """
  end

  @doc """
  TOTP enrollment block — the white QR wrapper, the "Can't scan?" setup-URI
  disclosure, and ONE `code_input` confirm form (`#mfa_form`, submits
  `confirm_mfa` as `mfa[otp]`). Shared by the profile page's voluntary
  setup (`variant={:split}` — QR beside the guidance) and the enforced-MFA
  interstitial (`:stacked` — centered in the narrow auth card). The page
  passes its own submit/cancel buttons via `:actions`.

      <.mfa_enrollment qr_svg={@mfa_qr_svg} uri={@mfa_uri} form={@mfa_form} variant={:split}>
        <:instructions>Scan with your authenticator, then confirm.</:instructions>
        <:actions>
          <.button phx-disable-with="Verifying...">Confirm and enable</.button>
        </:actions>
      </.mfa_enrollment>
  """
  attr :qr_svg, :string, required: true, doc: "server-generated SVG (MfaQr) — never user input"
  attr :uri, :string, required: true, doc: "the otpauth:// provisioning URI"
  attr :form, Phoenix.HTML.Form, required: true
  attr :variant, :atom, default: :stacked, values: [:stacked, :split]

  attr :error, :string,
    default: nil,
    doc: "a rejected-code error, rendered inline at the code input"

  slot :instructions
  slot :actions, required: true

  def mfa_enrollment(assigns) do
    ~H"""
    <div class={mfa_enrollment_wrapper(@variant)}>
      <div class="flex flex-col items-center gap-2">
        <%!-- raw/1 is safe here: the SVG comes from MfaQr rendering OUR
             provisioning URI server-side, never from user input (IL-16). --%>
        <div class="rounded-lg bg-white p-3 [&>svg]:block [&>svg]:h-60 [&>svg]:w-60">
          {Phoenix.HTML.raw(@qr_svg)}
        </div>
        <p class="text-[11px] text-zinc-400">Scan with your authenticator</p>
      </div>

      <div class="space-y-3">
        <p :if={@instructions != []} class="text-sm text-zinc-300">
          {render_slot(@instructions)}
        </p>

        <.disclosure>
          <:summary>Can't scan? Use a setup URI</:summary>
          <div class="flex items-center gap-2">
            <code id="mfa-uri" class="flex-1 break-all font-mono text-[11px] text-zinc-200">
              {@uri}
            </code>
            <.copy_button
              target="#mfa-uri"
              class="bg-brand-500/20 px-2 text-brand-100 hover:bg-brand-500/30 font-semibold"
            >
              Copy
            </.copy_button>
          </div>
        </.disclosure>

        <.simple_form for={@form} id="mfa_form" phx-submit="confirm_mfa">
          <.code_input id="mfa-otp" name="mfa[otp]" numeric label="6-digit code" error={@error} />
          <:actions>
            {render_slot(@actions)}
          </:actions>
        </.simple_form>
      </div>
    </div>
    """
  end

  defp mfa_enrollment_wrapper(:stacked), do: "space-y-4"

  defp mfa_enrollment_wrapper(:split), do: "grid grid-cols-1 gap-6 sm:grid-cols-[auto_1fr]"
end
