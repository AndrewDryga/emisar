defmodule EmisarWeb.ApplicationTest do
  use ExUnit.Case, async: true

  describe "scrub_sentry_event/1" do
    test "the Sentry before_send scrubber drops PII and redacts secrets" do
      event = %Sentry.Event{
        event_id: String.duplicate("a", 32),
        timestamp: "2026-07-16T00:00:00",
        request: %Sentry.Interfaces.Request{
          url: "https://emisar.dev/app?email=person@example.com",
          query_string: %{"email" => "person@example.com", "token" => "query-secret"},
          data: %{"password" => "body-secret"},
          cookies: %{"session" => "session-secret"},
          headers: %{"authorization" => "bearer-secret"},
          env: %{"secret" => "env-secret"}
        },
        user: %{id: "user-id", email: "person@example.com", ip_address: "203.0.113.10"},
        extra: %{
          "api_key" => "api-secret",
          "nested" => %{"password" => "password-secret", "safe" => "kept"}
        }
      }

      scrubbed = EmisarWeb.Application.scrub_sentry_event(event)

      assert scrubbed.request.url == "https://emisar.dev/app"
      assert scrubbed.request.query_string == nil
      assert scrubbed.request.data == nil
      assert scrubbed.request.cookies == nil
      assert scrubbed.request.headers == nil
      assert scrubbed.request.env == nil
      assert scrubbed.user == %{}
      assert scrubbed.extra["api_key"] == "[REDACTED]"
      assert scrubbed.extra["nested"]["password"] == "[REDACTED]"
      assert scrubbed.extra["nested"]["safe"] == "kept"
    end

    test "the Sentry before_send scrubber drops inspected crash state" do
      totp_seed = "JBSWY3DPEHPK3PXP"
      recovery_code = "recovery-code-once"

      socket_state =
        inspect(%Phoenix.LiveView.Socket{
          assigns: %{
            mfa_secret: totp_seed,
            mfa_recovery_codes: [recovery_code]
          }
        })

      assert socket_state =~ totp_seed
      assert socket_state =~ recovery_code

      event = %Sentry.Event{
        event_id: String.duplicate("a", 32),
        timestamp: "2026-09-02T00:00:00",
        extra: %{
          "last_message" => socket_state,
          "ranch_extra" => socket_state,
          :crash_reason => socket_state,
          :genserver_state => socket_state,
          :safe => "kept"
        }
      }

      scrubbed = EmisarWeb.Application.scrub_sentry_event(event)
      encoded_extra = Jason.encode!(scrubbed.extra)

      assert scrubbed.extra.safe == "kept"
      refute Map.has_key?(scrubbed.extra, :genserver_state)
      refute Map.has_key?(scrubbed.extra, "last_message")
      refute Map.has_key?(scrubbed.extra, :crash_reason)
      refute Map.has_key?(scrubbed.extra, "ranch_extra")
      refute encoded_extra =~ totp_seed
      refute encoded_extra =~ recovery_code
    end

    test "the scrubber redacts a secret-shaped struct dump in the formatted message" do
      totp_seed = "JBSWY3DPEHPK3PXP"

      event = %Sentry.Event{
        event_id: String.duplicate("a", 32),
        timestamp: "2026-09-04T00:00:00",
        message: %Sentry.Interfaces.Message{
          message:
            "GenServer %s terminating: ** (MatchError) no match of right hand " <>
              "side value: %{mfa_secret: \"#{totp_seed}\", safe: \"kept\"}",
          formatted:
            "GenServer #PID<0.123.0> terminating: ** (MatchError) no match of right " <>
              "hand side value: %{mfa_secret: \"#{totp_seed}\", safe: \"kept\"}",
          params: ["#PID<0.123.0>"]
        }
      }

      scrubbed = EmisarWeb.Application.scrub_sentry_event(event)

      refute scrubbed.message.formatted =~ totp_seed
      refute scrubbed.message.message =~ totp_seed
      assert scrubbed.message.formatted =~ "mfa_secret: [REDACTED]"
      assert scrubbed.message.formatted =~ ~s(safe: "kept")
    end

    test "the scrubber cuts the inspected process state a crash message carries as its tail" do
      totp_seed = "JBSWY3DPEHPK3PXP"
      recovery_code = "recovery-code-once"

      socket_state =
        inspect(%Phoenix.LiveView.Socket{
          assigns: %{mfa_secret: totp_seed, mfa_recovery_codes: [recovery_code]}
        })

      event = %Sentry.Event{
        event_id: String.duplicate("a", 32),
        timestamp: "2026-09-04T00:00:00",
        message: %Sentry.Interfaces.Message{
          formatted:
            "GenServer #PID<0.123.0> terminating\n** (RuntimeError) boom" <>
              "\nLast message: {:save, \"#{recovery_code}\"}\nState: #{socket_state}"
        }
      }

      scrubbed = EmisarWeb.Application.scrub_sentry_event(event)

      assert scrubbed.message.formatted ==
               "GenServer #PID<0.123.0> terminating\n** (RuntimeError) boom"

      refute scrubbed.message.formatted =~ totp_seed
      refute scrubbed.message.formatted =~ recovery_code
    end

    test "the scrubber redacts a secret-shaped struct dump in the exception value" do
      api_key = "emk_live_abcdefghijklmnop"

      event = %Sentry.Event{
        event_id: String.duplicate("a", 32),
        timestamp: "2026-09-04T00:00:00",
        exception: [
          %Sentry.Interfaces.Exception{
            type: "MatchError",
            value: ~s(no match of right hand side value: %{"token" => "#{api_key}", "id" => "7"})
          }
        ]
      }

      scrubbed = EmisarWeb.Application.scrub_sentry_event(event)
      [exception] = scrubbed.exception

      refute exception.value =~ api_key
      assert exception.value =~ ~s("token" => [REDACTED])
      assert exception.value =~ ~s("id" => "7")
    end
  end
end
