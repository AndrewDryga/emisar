# A spend ceiling with someone watching it.
#
# `DATA_READ` audit logging is on for `allServices` and the pack registry bucket
# is anonymously readable, so an unauthenticated caller can drive the Cloud
# Logging bill by reading packs in a loop. There was no budget anywhere, which
# means the first signal would have been an invoice.
#
# Count-gated on the billing account id: a fork, or a scratch project billing
# elsewhere, gets no budget rather than a plan that fails on someone else's
# billing account.

resource "google_billing_budget" "emisar" {
  count = var.billing_account_id == "" ? 0 : 1

  billing_account = var.billing_account_id
  display_name    = "Emisar Monthly Spend"

  budget_filter {
    projects = ["projects/${data.google_project.current.number}"]
  }

  amount {
    specified_amount {
      currency_code = "USD"
      units         = tostring(var.monthly_budget_amount)
    }
  }

  # Three tiers on purpose. 50% and 90% are ACTUAL spend — the ordinary "this
  # month is running hot" signal. 100% is FORECASTED, so it fires on the
  # trajectory rather than after the money is gone, which is the only one of the
  # three that can still change the outcome.
  threshold_rules {
    threshold_percent = 0.5
    spend_basis       = "CURRENT_SPEND"
  }

  threshold_rules {
    threshold_percent = 0.9
    spend_basis       = "CURRENT_SPEND"
  }

  threshold_rules {
    threshold_percent = 1.0
    spend_basis       = "FORECASTED_SPEND"
  }

  all_updates_rule {
    monitoring_notification_channels = local.paging_notification_channels
    # The billing-account admins get it too. A budget that only reaches the
    # on-call rotation is invisible to whoever can actually authorize more spend.
    disable_default_iam_recipients = false
  }

  depends_on = [google_project_service.apis]
}
