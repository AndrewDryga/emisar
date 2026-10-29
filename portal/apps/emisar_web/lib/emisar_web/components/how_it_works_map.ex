defmodule EmisarWeb.HowItWorksMap do
  @moduledoc """
  The animated "How it works" map on /how-it-works: your agent, emisar's hosted control plane,
  and the runner on your server, told in ten steps over four acts (Before, Set up, Requests,
  Record).

  The server renders the finished picture (the record step) and every step's caption, so the
  page reads in full without JavaScript; `assets/js/how_it_works_map.js` replays the steps, and
  the styles live under `[data-hiw]` in `assets/css/app.css`. The `data-k` keys name the parts
  the script shows, lights, and moves; `data-port` marks where a wire attaches.
  """
  use Phoenix.Component
  import EmisarWeb.CoreComponents, only: [icon: 1]

  def how_it_works_map(assigns) do
    ~H"""
    <div data-hiw class="hiw" data-s="10" data-act="3">
      <div class="hiw-panel">
        <div class="hiw-head">
          <%!-- Two groups: the world before emisar, then the three acts with it. --%>
          <div class="hiw-acts-row" role="group" aria-label="Story chapters">
            <div class="hiw-acts">
              <button type="button" class="hiw-act" data-hiw-act="0">
                Before<span class="hiw-act-x"> emisar</span>
              </button>
            </div>
            <div class="hiw-acts">
              <button type="button" class="hiw-act" data-hiw-act="1">Set up</button>
              <button type="button" class="hiw-act" data-hiw-act="2">Requests</button>
              <button type="button" class="hiw-act" data-hiw-act="3" aria-current="step">Record</button>
            </div>
          </div>
        </div>

        <figure
          class="hiw-fig"
          aria-label="Diagram of how emisar works: your agent, the hosted emisar control plane, and the runner on your server, told in ten steps"
        >
          <figcaption class="hiw-nar">
            <div class="hiw-nar-text">
              <p class="hiw-count" aria-hidden="true"><b data-hiw-count>10</b> / 10</p>
              <div class="hiw-cap">
                <p class="hiw-cap-live" data-hiw-cap aria-live="polite" aria-atomic="true">
                  <span class="hiw-sr">Step 10 of 10. </span><strong class="hiw-cap-t">On the record.</strong>
                  <span class="hiw-cap-s">The audit trail holds all three decisions, the
                  <span class="w-deny">refused</span>
                  one included, and the runner keeps its own hash-chained journal of the two runs on the host.</span>
                </p>
                <p class="hiw-cap-size" data-hiw-cap-n="1" aria-hidden="true">
                  <strong class="hiw-cap-t">Before emisar: an SSH key.</strong>
                  <span class="hiw-cap-s">The agent runs commands itself. It reads a config file, the database password flows straight back to it, and it restarts Postgres with nothing checking first.</span>
                </p>
                <p class="hiw-cap-size" data-hiw-cap-n="2" aria-hidden="true">
                  <strong class="hiw-cap-t">Before emisar: one wrong guess.</strong>
                  <span class="hiw-cap-s">The agent means to reset the dev database, but on this server
                  <code>$DB_HOST</code>
                  points at production. The drop runs at once, and there is no undo.</span>
                </p>
                <p class="hiw-cap-size" data-hiw-cap-n="3" aria-hidden="true">
                  <strong class="hiw-cap-t">Install the runner.</strong>
                  <span class="hiw-cap-s">One command installs a small open-source runner. It connects out over TLS, so you open no inbound port.</span>
                </p>
                <p class="hiw-cap-size" data-hiw-cap-n="4" aria-hidden="true">
                  <strong class="hiw-cap-t">emisar in the middle.</strong>
                  <span class="hiw-cap-s">The hosted control plane sits between agent and server, with identity, policy, approvals, and an audit trail.</span>
                </p>
                <p class="hiw-cap-size" data-hiw-cap-n="5" aria-hidden="true">
                  <strong class="hiw-cap-t">Connect your agent.</strong>
                  <span class="hiw-cap-s">Your agent connects over MCP to one server with 14 tools. It no longer needs the SSH key.</span>
                </p>
                <p class="hiw-cap-size" data-hiw-cap-n="6" aria-hidden="true">
                  <strong class="hiw-cap-t">Add packs.</strong>
                  <span class="hiw-cap-s">Packs add ready-made actions, each a fixed command with checked arguments: 1,840 actions in 103 packs.</span>
                </p>
                <p class="hiw-cap-size" data-hiw-cap-n="7" aria-hidden="true">
                  <strong class="hiw-cap-t">A request runs.</strong>
                  <span class="hiw-cap-s">Policy <span class="w-pass">allows</span>
                  the low-risk <code>postgres.slow_queries</code>. The runner checks the trusted pack and its local rules, runs it, and redacts the output on the host.</span>
                </p>
                <p class="hiw-cap-size" data-hiw-cap-n="8" aria-hidden="true">
                  <strong class="hiw-cap-t">A person approves.</strong>
                  <span class="hiw-cap-s"><code>postgres.terminate_backend</code>
                  is high risk, so it <span class="w-warn">waits</span>
                  until a person approves it in the console or by email, then runs the same way.</span>
                </p>
                <p class="hiw-cap-size" data-hiw-cap-n="9" aria-hidden="true">
                  <strong class="hiw-cap-t">Refused.</strong>
                  <span class="hiw-cap-s">Rebooting the host with <code>linux.reboot_host</code>
                  is critical, so policy <span class="w-deny">refuses</span>
                  it, and it never reaches your server.</span>
                </p>
                <p class="hiw-cap-size" data-hiw-cap-n="10" aria-hidden="true">
                  <strong class="hiw-cap-t">On the record.</strong>
                  <span class="hiw-cap-s">The audit trail holds all three decisions, the
                  <span class="w-deny">refused</span>
                  one included, and the runner keeps its own hash-chained journal of the two runs on the host.</span>
                </p>
              </div>
            </div>
            <div class="hiw-ctl">
              <div class="hiw-btns">
                <button type="button" class="hiw-cb hiw-prev" data-hiw-prev><span class="hiw-sr">Previous step</span><.icon
                  name="breadcrumb.separator"
                  class="h-4 w-4"
                /></button>
                <button type="button" class="hiw-cb hiw-play is-paused" data-hiw-play><span
                  class="hiw-ico"
                  aria-hidden="true"
                ><svg class="i-pause" viewBox="0 0 16 16" width="16" height="16"><rect
                  x="4"
                  y="3"
                  width="2.6"
                  height="10"
                  rx=".8"
                  fill="currentColor"
                /><rect x="9.4" y="3" width="2.6" height="10" rx=".8" fill="currentColor" /></svg><span class="i-play"><.icon
                  name="action.execute"
                  class="h-4 w-4"
                /></span></span><span class="hiw-sr" data-hiw-play-label>Play</span></button>
                <button type="button" class="hiw-cb hiw-next" data-hiw-next><span class="hiw-sr">Next step</span><.icon
                  name="breadcrumb.separator"
                  class="h-4 w-4"
                /></button>
              </div>
              <div class="hiw-prog" role="group" aria-label="Steps">
                <button type="button" class="hiw-seg is-first is-done" data-hiw-seg="1"><i></i><span class="hiw-sr">Step 1 of 10: Before emisar, an SSH key</span></button>
                <button type="button" class="hiw-seg is-done" data-hiw-seg="2"><i></i><span class="hiw-sr">Step 2 of 10: Before emisar, one wrong guess</span></button>
                <button type="button" class="hiw-seg is-first is-done" data-hiw-seg="3"><i></i><span class="hiw-sr">Step 3 of 10: Install the runner</span></button>
                <button type="button" class="hiw-seg is-done" data-hiw-seg="4"><i></i><span class="hiw-sr">Step 4 of 10: emisar in the middle</span></button>
                <button type="button" class="hiw-seg is-done" data-hiw-seg="5"><i></i><span class="hiw-sr">Step 5 of 10: Connect your agent</span></button>
                <button type="button" class="hiw-seg is-done" data-hiw-seg="6"><i></i><span class="hiw-sr">Step 6 of 10: Add packs</span></button>
                <button type="button" class="hiw-seg is-first is-done" data-hiw-seg="7"><i></i><span class="hiw-sr">Step 7 of 10: A request runs</span></button>
                <button type="button" class="hiw-seg is-done" data-hiw-seg="8"><i></i><span class="hiw-sr">Step 8 of 10: A person approves</span></button>
                <button type="button" class="hiw-seg is-done" data-hiw-seg="9"><i></i><span class="hiw-sr">Step 9 of 10: Refused</span></button>
                <button
                  type="button"
                  class="hiw-seg is-first is-done"
                  data-hiw-seg="10"
                  aria-current="step"
                ><i></i><span class="hiw-sr">Step 10 of 10: On the record</span></button>
              </div>
            </div>
          </figcaption>
          <div class="hiw-stage" data-hiw-stage aria-hidden="true">
            <svg class="hiw-wires" data-hiw-wires></svg>

            <div class="hiw-col hiw-a" data-k="col-a">
              <div class="hiw-card hiw-agent hiw-fx" data-k="agent">
                <span class="hiw-port pd p-r" data-port="ag" data-k="pt-ag" style="top:53px"></span>
                <span class="hiw-port pm p-b" data-port="ag" data-k="pt-ag" style="left:50%"></span>
                <span class="hiw-port pd p-b" data-port="ag-b" style="left:50%"></span>
                <p class="hiw-eyebrow">Your agent</p>
                <ul class="hiw-ags">
                  <li class="hiw-ag" data-k="ag-claude">
                    <span class="is-claude"><.icon name="agent.claude" class="h-4 w-4" /></span><span class="hiw-ag-n">Claude.ai</span><span
                      class="hiw-ag-m hiw-fx is-off"
                      data-k="m-oa1"
                    >OAuth</span>
                  </li>
                  <li class="hiw-ag">
                    <span><.icon name="agent.chatgpt" class="h-4 w-4" /></span><span class="hiw-ag-n">ChatGPT</span><span
                      class="hiw-ag-m hiw-fx is-off"
                      data-k="m-oa2"
                    >OAuth</span>
                  </li>
                  <li class="hiw-ag">
                    <span><.icon name="product.agent" class="h-4 w-4" /></span><span class="hiw-ag-n">Cursor</span><span
                      class="hiw-ag-m hiw-fx is-off"
                      data-k="m-br"
                    >bridge</span>
                  </li>
                </ul>
                <div class="hiw-agst hiw-grow hiw-fx" data-k="ag-st">
                  <div class="hiw-status">
                    <span class="hiw-dot is-on" data-k="ag-dot"></span>
                    <span class="hiw-swap hiw-mono hiw-s1" data-k="ag1"><span class="on">emisar</span><span></span></span>
                    <span class="hiw-swap hiw-s2" data-k="ag2"><span class="on">connected over MCP</span><span></span></span>
                  </div>
                </div>
              </div>
              <div class="hiw-card hiw-you hiw-fx" data-k="you">
                <span class="hiw-port p-r" data-port="you" style="top:32px"></span>
                <span class="hiw-port p-t" data-port="you-t" style="left:50%"></span>
                <span class="hiw-tile is-n"><.icon name="identity.person" class="h-5 w-5" /></span>
                <span class="hiw-t"><span class="hiw-name">You</span><span
                  class="hiw-swap hiw-desc"
                  data-k="you-sub"
                ><span class="on">Console or email</span><span></span></span></span>
              </div>
              <div class="hiw-card hiw-ask hiw-fx is-off" data-k="ask">
                <div class="hiw-ask-h">
                  <span class="hiw-eyebrow"><.icon name="state.awaiting_human" class="h-4 w-4" />Approval needed</span><span class="hiw-tier">high</span>
                </div>
                <p class="hiw-mono hiw-ask-id">postgres.terminate_backend</p>
                <p class="hiw-ask-d">pid 48213 · from Claude.ai</p>
                <div class="hiw-ask-f">
                  <div class="hiw-ask-b hiw-fx" data-k="ask-b">
                    <span class="hiw-btn-d">Deny</span><span class="hiw-btn-a" data-k="ask-ok"><.icon
                      name="action.approve"
                      class="h-3.5 w-3.5"
                    />Approve</span>
                  </div>
                  <div class="hiw-ask-done hiw-fx is-off" data-k="ask-done">
                    <.icon name="state.success" class="h-4 w-4" />Approved by you
                  </div>
                </div>
              </div>
            </div>

            <div class="hiw-col hiw-ln1" data-k="col-l1">
              <span class="hiw-lane-t hiw-mono hiw-fx is-off" data-k="lb-mcp">MCP</span>
              <span class="hiw-badge hiw-badge-key is-rose hiw-fx is-off" data-k="key"><.icon
                name="identity.credential"
                class="h-3.5 w-3.5"
              /></span>
            </div>

            <div class="hiw-col hiw-b" data-k="col-b">
              <div class="hiw-chat hiw-fx is-off" data-k="chat-a">
                <div class="hiw-chat-h">
                  <span class="is-claude"><.icon name="agent.claude" class="h-4 w-4" /></span>Claude.ai
                </div>
                <div class="hiw-chat-b">
                  <p class="hiw-say">
                    “The dev database is behind. Resetting it so the migration can run again.”
                  </p>
                </div>
              </div>
              <ul class="hiw-dz hiw-dz-a">
                <li class="hiw-fx is-off" data-k="dza1">
                  <.icon name="state.warning" class="h-4 w-4" />Meant dev, dropped production
                </li>
                <li class="hiw-fx is-off" data-k="dza2">
                  <.icon name="state.warning" class="h-4 w-4" />Nothing asks first, and there is no undo
                </li>
              </ul>
              <div class="hiw-chat hiw-fx is-off" data-k="chat-b">
                <div class="hiw-chat-h">
                  <span class="is-claude"><.icon name="agent.claude" class="h-4 w-4" /></span>Straight back to Claude.ai
                </div>
                <div class="hiw-chat-b" phx-no-format>
                  <p class="hiw-chat-who"><.icon name="interface.cli" class="h-3.5 w-3.5" />Output of cat /etc/checkout/env</p>
                  <span class="hiw-cl">DATABASE_URL=<wbr />postgres://<span class="hiw-sec">checkout:Hx7k9pQ2</span>@db-01</span>
                </div>
              </div>
              <ul class="hiw-dz hiw-dz-b">
                <li class="hiw-fx is-off" data-k="dzb1">
                  <.icon name="state.warning" class="h-4 w-4" />It can run whatever the account can
                </li>
                <li class="hiw-fx is-off" data-k="dzb2">
                  <.icon name="state.warning" class="h-4 w-4" />Nothing approves a command before it runs
                </li>
                <li class="hiw-fx is-off" data-k="dzb3">
                  <.icon name="state.warning" class="h-4 w-4" />Secrets in output go straight to the AI
                </li>
              </ul>
              <div class="hiw-card hiw-cp hiw-fx" data-k="cp" data-gate>
                <span class="hiw-port pd p-l" data-port="cp-l" data-k="pt-cpl" style="top:76px"></span>
                <span class="hiw-port pd p-r" data-port="cp-r" data-k="pt-cpr" style="top:76px"></span>
                <span class="hiw-port pd p-l" data-port="cp-ap" data-k="pt-cpa" style="top:172px"></span>
                <span class="hiw-port pm p-t" data-port="cp-l" data-k="pt-cpl" style="left:50%"></span>
                <span class="hiw-port pm p-b" data-port="cp-r" data-k="pt-cpr" style="left:50%"></span>
                <div class="hiw-cp-h hiw-fx" data-k="cp-h">
                  <svg
                    class="hiw-logo"
                    role="img"
                    aria-label="emisar"
                    fill="none"
                    viewBox="0 0 1320 390"
                  ><g stroke-linejoin="round" stroke-width="37">
                    <path stroke="currentColor" d="M96 50 19.5 195 96 340" /><path
                      stroke="#36e6a5"
                      d="m258 50 76.5 145L258 340"
                    />
                  </g><path stroke="currentColor" stroke-width="16" d="M177 84v69m0 84v69" /><circle
                    class="hiw-g hiw-g1"
                    cx="177"
                    cy="42.5"
                    r="34.5"
                    stroke="currentColor"
                    stroke-width="14"
                  /><circle
                    class="hiw-g hiw-g2"
                    cx="177"
                    cy="195"
                    r="34.5"
                    stroke="#36e6a5"
                    stroke-width="14"
                  /><circle
                    class="hiw-g hiw-g3"
                    cx="177"
                    cy="347.5"
                    r="34.5"
                    stroke="currentColor"
                    stroke-width="14"
                  /><path
                    fill="currentColor"
                    fill-rule="evenodd"
                    d="M1271 117.5v1l-1 1h-5l-1 1h-2l-1 1h-1l-2 2h-1l-3 3v1l-1 1v1l-1 1v1l-1 1v8l-3 3h-10l-1 1h-1l-1 1h-1l-5 5v1l-2 2v1l-1 1v2l-1 1v113h27v-117l1-1v-1l1-1v-1l4-4h1l1-1h2l1-1h53l1-1h2v-26Zm-211 0v1l-1 1v24h25l1 1h7l1-1h55l1 1h4l1 1h2l1 1h1l1 1h1l1 1h1l7 7v1l1 1v1l1 1v1l1 1v2l1 1v15l-1 1h-86l-1 1h-3l-1 1h-2l-1 1h-2l-1 1h-1l-1 1h-1l-2 2h-1l-2 2h-1l-5 5v1l-3 3v1l-1 1v1l-1 1v1l-1 1v1l-1 1v1l-1 1v2l-1 1v4l-1 1v21l1 1v3l1 1v1l1 1v2l1 1v1l1 1v1l2 2v1l2 2v1l7 7h1l2 2h1l2 2h1l1 1h1l1 1h2l1 1h2l1 1h62l1-1h1l1-1h1l6-6v-1l2-2v-1l2-2v-1l3-3v-1l3-3h9l1 1v1l1 1v19h24v-103l-1-1v-8l-1-1v-3l-1-1v-2l-1-1v-1l-1-1v-2l-1-1v-1l-2-2v-1l-1-1v-1l-4-4v-1l-5-5h-1l-3-3h-1l-2-2h-1l-1-1h-1l-1-1h-1l-1-1h-2l-1-1h-2l-1-1h-3l-1-1h-6l-1-1v-1Zm32 87 1-1h79l1 1v17l-1 1v1l-1 1v1l-3 3v1l-3 3v1l-2 2v1l-4 4v1l-3 3h-1l-2 2h-1l-1 1h-30l-1 1h-23l-1-1h-4l-1-1h-2l-2-2h-1l-5-5v-1l-1-1v-1l-1-1v-1l-1-1v-3l-1-1v-6l1-1v-4l1-1v-2l1-1v-1l1-1v-1l4-4h1l2-2h1l1-1Zm-156-87v1l-1 1h-8l-1 1h-3l-1 1h-2l-1 1h-2l-1 1h-1l-2 2h-1l-1 1h-1l-9 9v1l-2 2v1l-1 1v1l-1 1v2l-1 1v2l-1 1v3l-1 1v18l1 1v3l1 1v2l1 1v2l1 1v1l2 2v1l3 3v1l2 2h1l4 4h1l2 2h1l1 1h1l1 1h2l1 1h2l1 1h2l1 1h4l1 1h5l1 1h4l1 1h5l1 1h4l1 1h5l1 1h4l1 1h5l1 1h4l1 1h5l1 1h4l1 1h4l1 1h3l1 1h2l1 1h1l3 3v1l2 2v2l1 1v10l-1 1v2l-7 7h-2l-1 1h-1l-1 1h-96v24h106l1-1h3l1-1h1l1-1h1l1-1h1l1-1h1l2-2h1l7-7v-1l2-2v-1l1-1v-1l1-1v-1l1-1v-1l1-1v-3l1-1v-4l1-1v-14l-1-1v-5l-1-1v-2l-1-1v-1l-1-1v-1l-1-1v-1l-1-1v-1l-2-2v-1l-7-7h-1l-2-2h-1l-1-1h-1l-1-1h-2l-1-1h-1l-1-1h-3l-1-1h-4l-1-1h-5l-1-1h-4l-1-1h-5l-1-1h-5l-1-1h-4l-1-1h-5l-1-1h-4l-1-1h-4l-1-1h-4l-1-1h-5l-1-1h-5l-1-1h-4l-1-1h-1l-1-1h-1l-4-4v-1l-1-1v-2l-1-1v-11l1-1v-1l1-1v-1l5-5h1l1-1h1l1-1h5l1-1h87v-24l-1-1v-1Zm-92 0v154h27v-152l-1-1v-1Zm-201 0v1l-1 1h-9l-1 1h-3l-1 1h-2l-1 1h-1l-1 1h-2l-2 2h-1l-1 1h-1l-9 9v1l-2 2v1l-1 1v1l-1 1v1l-1 1v1l-1 1v2l-1 1v3l-1 1v4l-1 1v113h27v-109l1-1v-2l1-1v-2l2-2v-1l5-5h1l1-1h1l1-1h1l1-1h4l1-1h29l1 1h3l1 1h2l1 1h1l7 7v1l1 1v1l1 1v1l1 1v2l1 1v108h27v-107l1-1v-3l1-1v-2l1-1v-1l1-1v-1l4-4h1l2-2h1l1-1h2l1-1h3l1-1h30l1 1h3l1 1h1l1 1h1l1 1h1l5 5v1l2 2v1l1 1v2l1 1v10l1 1v79l-1 1v15l1 1v2l-1 1h28v-91l-1-1v-22l-1-1v-4l-1-1v-2l-1-1v-2l-1-1v-1l-1-1v-1l-1-1v-1l-1-1v-1l-3-3v-1l-6-6h-1l-3-3h-1l-1-1h-1l-1-1h-1l-1-1h-1l-1-1h-2l-1-1h-3l-1-1h-5l-1-1v-1h-57v1l-1 1v26l-1 1h-18l-1-1v-1l-1-1v-26Zm-169 0v1l-1 1h-7l-1 1h-3l-1 1h-2l-1 1h-1l-1 1h-2l-1 1h-1l-2 2h-1l-2 2h-1l-3 3h-1v1l-1 1h-1v1l-4 4v1l-2 2v1l-2 2v1l-1 1v1l-1 1v2l-1 1v1l-1 1v3l-1 1v3l-1 1v67l1 1v4l1 1v3l1 1v2l1 1v1l1 1v1l1 1v1l1 1v1l2 2v1l3 3v1l5 5h1l3 3h1l2 2h1l1 1h1l1 1h1l1 1h1l1 1h2l1 1h3l1 1h98v-24h-88l-1-1h-3l-1-1h-2l-1-1h-1l-1-1h-1l-8-8v-1l-1-1v-1l-1-1v-1l-1-1v-2l-1-1v-14l1-1h82l1-1h5l1-1h3l1-1h2l1-1h1l1-1h1l1-1h1l2-2h1l3-3h1l3-3v-1l3-3v-1l2-2v-1l1-1v-1l1-1v-1l1-1v-1l1-1v-3l1-1v-3l1-1v-17l-1-1v-4l-1-1v-3l-1-1v-1l-1-1v-1l-1-1v-1l-1-1v-1l-2-2v-1l-3-3v-1l-5-5h-1l-3-3h-1l-1-1h-1l-1-1h-1l-1-1h-1l-1-1h-2l-1-1h-3l-1-1h-7l-1-1v-1Zm0 27 1-1h55l1 1h3l1 1h1l1 1h1l1 1h1l5 5v1l1 1v1l1 1v1l1 1v2l1 1v10l-1 1v2l-1 1v1l-1 1v1l-7 7h-1l-1 1h-1l-1 1h-4l-1 1h-77l-1-1v-21l1-1v-4l1-1v-1l1-1v-1l1-1v-1l7-7h1l2-2h1l1-1h2l1-1Z"
                  /></svg><span class="hiw-desc">Hosted control plane</span>
                </div>
                <div class="hiw-row hiw-fx" data-k="r-id">
                  <span class="hiw-tile"><.icon name="identity.person" class="h-5 w-5" /></span>
                  <span class="hiw-t"><span class="hiw-name">Identity</span><span class="hiw-desc">Who is asking</span></span>
                  <span class="hiw-meta hiw-fx is-off" data-k="m-id">you</span>
                </div>
                <div class="hiw-row hiw-fx" data-k="r-pol">
                  <span class="hiw-tile"><.icon name="product.policy" class="h-5 w-5" /></span>
                  <span class="hiw-t"><span class="hiw-name">Policy</span><span class="hiw-desc">Decides by risk tier</span></span>
                  <span class="hiw-pills">
                    <span class="hiw-pill t-pass hiw-fx is-off" data-k="pp-pass"><.icon
                      name="state.success"
                      class="h-3 w-3"
                    /><span class="hiw-pt">Allowed</span></span>
                    <span class="hiw-pill t-warn hiw-fx is-off" data-k="pp-warn"><.icon
                      name="state.pending"
                      class="h-3 w-3"
                    /><span class="hiw-pt">Approval</span></span>
                    <span class="hiw-pill t-deny hiw-fx is-off" data-k="pp-deny"><.icon
                      name="state.denied"
                      class="h-3 w-3"
                    /><span class="hiw-pt">Denied</span></span>
                  </span>
                </div>
                <div class="hiw-row hiw-fx" data-k="r-ap">
                  <span class="hiw-tile"><.icon name="product.approval" class="h-5 w-5" /></span>
                  <span class="hiw-t"><span class="hiw-name">Approvals</span><span class="hiw-desc">A person signs off</span></span>
                  <span class="hiw-pills">
                    <span class="hiw-meta is-q hiw-fx is-off" data-k="m-skip">not needed</span>
                    <span class="hiw-pill t-pass hiw-fx is-off" data-k="pa-pass"><.icon
                      name="state.success"
                      class="h-3 w-3"
                    /><span class="hiw-pt">Approved</span></span>
                  </span>
                </div>
                <div class="hiw-row hiw-fx" data-k="r-au">
                  <span class="hiw-tile"><.icon name="product.audit" class="h-5 w-5" /></span>
                  <span class="hiw-t"><span class="hiw-name">Audit trail</span><span class="hiw-desc">Every decision, recorded</span></span>
                  <span></span>
                </div>
                <ol class="hiw-evs hiw-fx" data-k="evs">
                  <li class="hiw-evr hiw-grow hiw-fx" data-k="ev1">
                    <div class="hiw-ev">
                      <span class="hiw-ev-id hiw-mono">postgres.slow_queries</span><span class="hiw-pill sm t-pass"><.icon
                        name="state.success"
                        class="h-3 w-3"
                      /><span class="hiw-pt">Allowed</span></span>
                    </div>
                  </li>
                  <li class="hiw-evr hiw-grow hiw-fx" data-k="ev2">
                    <div class="hiw-ev">
                      <span class="hiw-ev-id hiw-mono">postgres.terminate_backend</span><span class="hiw-pill sm t-pass"><.icon
                        name="state.success"
                        class="h-3 w-3"
                      /><span class="hiw-pt">Approved</span></span>
                    </div>
                  </li>
                  <li class="hiw-evr hiw-grow hiw-fx" data-k="ev3">
                    <div class="hiw-ev">
                      <span class="hiw-ev-id hiw-mono">linux.reboot_host</span><span class="hiw-pill sm t-deny"><.icon
                        name="state.denied"
                        class="h-3 w-3"
                      /><span class="hiw-pt">Denied</span></span>
                    </div>
                  </li>
                </ol>
                <div class="hiw-card hiw-ask hiw-ask-m hiw-fx is-off" data-k="ask">
                  <div class="hiw-ask-h">
                    <span class="hiw-eyebrow"><.icon name="state.awaiting_human" class="h-4 w-4" />Approval needed</span><span class="hiw-tier">high</span>
                  </div>
                  <p class="hiw-mono hiw-ask-id">postgres.terminate_backend</p>
                  <p class="hiw-ask-d">pid 48213 · from Claude.ai</p>
                  <div class="hiw-ask-f">
                    <div class="hiw-ask-b hiw-fx" data-k="ask-b">
                      <span class="hiw-btn-d">Deny</span><span class="hiw-btn-a" data-k="ask-ok"><.icon
                        name="action.approve"
                        class="h-3.5 w-3.5"
                      />Approve</span>
                    </div>
                    <div class="hiw-ask-done hiw-fx is-off" data-k="ask-done">
                      <.icon name="state.success" class="h-4 w-4" />Approved by you
                    </div>
                  </div>
                </div>
              </div>
            </div>

            <div class="hiw-col hiw-ln2" data-k="col-l2">
              <span class="hiw-lane-t hiw-mono hiw-fx" data-k="lb-tls">TLS</span>
            </div>

            <span class="hiw-sp" aria-hidden="true"></span>

            <div class="hiw-col hiw-c" data-k="col-c">
              <div class="hiw-region hiw-fx" data-k="region">
                <span class="hiw-redact emisar-icon-mono hiw-fx is-off" data-k="redact"><.icon
                  name="security.redacted"
                  class="h-3.5 w-3.5"
                /></span>
                <p class="hiw-eyebrow">
                  <.icon name="infrastructure.host" class="h-3.5 w-3.5" />Your server
                </p>
                <div class="hiw-con hiw-fx is-off" data-k="con">
                  <span class="hiw-port pd p-l" data-port="sh" style="top:32px"></span>
                  <span class="hiw-port pm p-t" data-port="sh" style="left:50%"></span>
                  <div class="hiw-con-h">
                    <.icon name="interface.cli" class="h-3.5 w-3.5" /><span class="hiw-mono">ops@prod-db</span><span
                      class="hiw-swap hiw-con-who"
                      data-k="con-who"
                    ><span class="on">you</span><span></span></span>
                  </div>
                  <div class="hiw-con-bs" phx-no-format>
                    <div class="hiw-con-b hiw-fx is-off" data-k="con-a">
                      <span class="hiw-cl cmd hiw-fx is-off" data-k="a1">psql -h "$DB_HOST" -c 'DROP DATABASE checkout'</span>
                      <span class="hiw-cl trace hiw-fx is-off" data-k="a2">+ psql -h <span class="hiw-sec">prod-db-01</span> -c 'DROP DATABASE checkout'</span>
                      <span class="hiw-cl boom hiw-fx is-off" data-k="a3">DROP DATABASE</span>
                    </div>
                    <div class="hiw-con-b hiw-fx is-off" data-k="con-b">
                      <span class="hiw-cl cmd hiw-fx is-off" data-k="b1">cat /etc/checkout/env</span>
                      <span class="hiw-cl hiw-fx is-off" data-k="b2">DATABASE_URL=<wbr />postgres://<span class="hiw-sec">checkout:Hx7k9pQ2</span>@db-01</span>
                      <span class="hiw-cl cmd hiw-fx is-off" data-k="b3">sudo systemctl restart postgresql</span>
                    </div>
                    <div class="hiw-con-b hiw-fx is-off" data-k="con-c">
                      <span class="hiw-cl cmd hiw-fx is-off" data-k="c1">curl -fsSL https://emisar.dev/install.sh | sudo bash</span>
                      <span class="hiw-cl hiw-fx is-off" data-k="c2">[install] downloading emisar</span>
                      <span class="hiw-cl hiw-fx is-off" data-k="c3">[install] checksum verified</span>
                      <span class="hiw-cl ok hiw-fx is-off" data-k="c4">runner started · outbound only</span>
                    </div>
                  </div>
                </div>
                <div class="hiw-card hiw-runner hiw-fx has-log" data-k="runner">
                  <span class="hiw-port pd p-l" data-port="rn" data-k="pt-rn" style="top:28px"></span>
                  <span class="hiw-port pm p-t" data-port="rn" data-k="pt-rn" style="left:50%"></span>
                  <span class="hiw-port p-b rp-1" data-port="rn-1"></span>
                  <span class="hiw-port p-b rp-2" data-port="rn-2"></span>
                  <span class="hiw-port p-b rp-3" data-port="rn-3"></span>
                  <div class="hiw-rn-h">
                    <span class="hiw-tile"><.icon name="product.runner" class="h-5 w-5" /></span>
                    <span class="hiw-t"><span class="hiw-name">Runner</span><span class="hiw-desc">Open source</span></span>
                    <span class="hiw-rn-st"><span class="hiw-dot is-on" data-k="rn-dot"></span><span
                      class="hiw-swap"
                      data-k="rn-st"
                    ><span class="on">online</span><span></span></span></span>
                  </div>
                  <div class="hiw-rn-body">
                    <div class="hiw-packs-w hiw-grow hiw-fx" data-k="packs">
                      <div class="hiw-packs">
                        <span class="hiw-pack hiw-mono hiw-fx" data-k="pk1"><.icon
                          name="product.pack"
                          class="h-3.5 w-3.5"
                        />linux-core</span>
                        <span class="hiw-pack hiw-mono hiw-fx" data-k="pk2"><.icon
                          name="product.pack"
                          class="h-3.5 w-3.5"
                        />postgres</span>
                        <span class="hiw-pack hiw-mono hiw-fx" data-k="pk3"><.icon
                          name="product.pack"
                          class="h-3.5 w-3.5"
                        />nginx</span>
                        <span class="hiw-pack hiw-mono hiw-fx" data-k="pk4"><.icon
                          name="product.pack"
                          class="h-3.5 w-3.5"
                        />kubernetes</span>
                      </div>
                    </div>
                    <div class="hiw-term-w">
                      <div class="hiw-term hiw-fx is-journal is-lit" data-k="term">
                        <span class="hiw-swap hiw-mono hiw-term-l" data-k="rl0"><span class="on">journal · hash-chained</span><span></span></span>
                        <span class="hiw-swap hiw-mono hiw-term-1" data-k="rl1"><span class="on"><span class="jd"></span>postgres.slow_queries</span><span></span></span>
                        <span class="hiw-swap hiw-mono hiw-term-2" data-k="rl2"><span class="on"><span class="jd"></span>postgres.terminate_backend</span><span></span></span>
                      </div>
                    </div>
                  </div>
                </div>
                <div class="hiw-svcs">
                  <div class="hiw-svc" data-k="svc-pg">
                    <span class="hiw-port p-t" data-port="pg" style="left:50%;top:9px"></span><.icon
                      name="infrastructure.database"
                      class="h-5 w-5"
                    /><span>Postgres</span>
                  </div>
                  <div class="hiw-svc" data-k="svc-ngx">
                    <span class="hiw-port p-t" data-port="ngx" style="left:50%;top:9px"></span><.icon
                      name="infrastructure.network"
                      class="h-5 w-5"
                    /><span>nginx</span>
                  </div>
                  <div class="hiw-svc" data-k="svc-k8s">
                    <span class="hiw-port p-t" data-port="k8s" style="left:50%;top:9px"></span><.icon
                      name="infrastructure.kubernetes"
                      class="h-5 w-5"
                    /><span>Kubernetes</span>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </figure>
      </div>
    </div>
    """
  end
end
