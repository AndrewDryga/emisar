#!/usr/bin/env python3
"""Fixed Stripe billing operations. API contract: 2026-08-26.dahlia.

Only the descriptor's operation and named environment arguments reach this
client. Credentials, evidence and request bodies never enter process argv.
"""

import hashlib
import json
import os
import re
import stat
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid

VERSION = "2026-08-26.dahlia"
MAX_RESPONSE = 8 * 1024 * 1024


class Failure(Exception):
    pass


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def arg(name, default=""):
    return os.environ.get("ARG_" + name.upper(), default)


def integer(name):
    return int(arg(name))


def boolean(name):
    return arg(name).lower() == "true"


def scalar(value):
    if isinstance(value, dict):
        value = value.get("id")
    if value is None or isinstance(value, (bool, int, float)):
        return value
    if not isinstance(value, str):
        raise Failure("Unexpected provider field type")
    # Explicit projections exclude secrets and arbitrary metadata. Text clipping
    # additionally bounds hostile provider-controlled names and descriptions.
    return "".join(c if ord(c) >= 32 else " " for c in value)[:256]


def at(obj, path):
    for part in path.split("."):
        if not isinstance(obj, dict):
            return None
        obj = obj.get(part)
    return obj


def evidence_text(value):
    clipped = value[:20000]
    while len(json.dumps(clipped, ensure_ascii=False).encode()) > 40000:
        clipped = clipped[:len(clipped) * 9 // 10]
    return clipped


FIELDS = {
    "customer": "id created livemode email name currency balance delinquent default_source invoice_settings.default_payment_method invoice_settings.default_tax_rates deleted",
    "payment_intent": "id created livemode customer amount amount_received amount_capturable currency status capture_method confirmation_method latest_charge payment_method canceled_at cancellation_reason last_payment_error.type last_payment_error.code last_payment_error.decline_code next_action.type",
    "charge": "id created livemode customer amount amount_captured amount_refunded currency status paid captured disputed refunded payment_intent balance_transaction failure_code outcome.type outcome.network_status outcome.reason outcome.risk_level payment_method payment_method_details.type payment_method_details.card.brand payment_method_details.card.last4 payment_method_details.card.checks.cvc_check payment_method_details.card.checks.address_postal_code_check",
    "refund": "id created amount currency status reason failure_reason charge payment_intent balance_transaction failure_balance_transaction pending_reason destination_details.card.reference destination_details.card.reference_status destination_details.card.reference_type",
    "invoice": "id created livemode customer subscription status currency amount_due amount_paid amount_remaining amount_overpaid subtotal total starting_balance ending_balance collection_method attempted attempt_count next_payment_attempt auto_advance due_date default_payment_method parent.subscription_details.subscription status_transitions.finalized_at status_transitions.paid_at status_transitions.voided_at status_transitions.marked_uncollectible_at last_finalization_error.type last_finalization_error.code",
    "line_item": "id amount currency quantity description period.start period.end pricing.type pricing.price_details.price pricing.price_details.product parent.type parent.invoice_item_details.invoice_item parent.subscription_item_details.subscription parent.subscription_item_details.subscription_item parent.subscription_item_details.proration",
    "invoice_payment": "id created invoice amount_requested amount_paid currency status is_default payment.type payment.payment_intent payment.charge payment.payment_record status_transitions.paid_at status_transitions.canceled_at",
    "subscription": "id created livemode customer status currency latest_invoice default_payment_method collection_method cancel_at_period_end cancel_at canceled_at ended_at trial_start trial_end billing_cycle_anchor pause_collection.behavior pause_collection.resumes_at cancellation_details.reason",
    "subscription_item": "id created quantity current_period_start current_period_end price.id price.product price.currency price.unit_amount price.recurring.interval price.recurring.interval_count",
    "dispute": "id created livemode charge payment_intent amount currency status reason is_charge_refundable evidence_details.due_by evidence_details.has_evidence evidence_details.past_due evidence_details.submission_count",
    "event": "id created livemode type api_version pending_webhooks request.id data.object.id data.object.object",
    "balance_transaction": "id created available_on amount currency fee net status type reporting_category source exchange_rate",
    "customer_balance_transaction": "id created customer amount currency ending_balance type invoice credit_note",
    "payout": "id created livemode amount currency status arrival_date automatic method type balance_transaction failure_balance_transaction failure_code reconciliation_status",
    "credit_note": "id created livemode customer invoice amount currency status type reason pre_payment_amount post_payment_amount out_of_band_amount customer_balance_transaction voided_at",
    "payment_method": "id created customer type card.brand card.last4 card.exp_month card.exp_year card.funding card.checks.cvc_check card.checks.address_postal_code_check",
    "file": "id created purpose type size expires_at",
}

# Lists deliberately use compact records. Full diagnostics are retrieved by ID.
LIST_FIELDS = {
    "customer": "id created email name balance currency delinquent",
    "payment_intent": "id created customer amount currency status latest_charge",
    "charge": "id created customer amount amount_refunded currency status payment_intent",
    "refund": "id created charge amount currency status failure_reason",
    "invoice": "id created customer amount_due amount_remaining currency status",
    "subscription": "id customer status currency latest_invoice cancel_at_period_end",
    "dispute": "id charge amount currency status reason evidence_details.due_by",
    "credit_note": "id invoice amount currency status type",
    "payout": "id amount currency status arrival_date failure_code",
}

TEXT_EVIDENCE = (
    "access_activity_log billing_address cancellation_policy_disclosure cancellation_rebuttal "
    "customer_email_address customer_name customer_purchase_ip duplicate_charge_explanation "
    "duplicate_charge_id product_description refund_policy_disclosure refund_refusal_explanation "
    "service_date shipping_address shipping_carrier shipping_date shipping_tracking_number uncategorized_text"
).split()
FILE_EVIDENCE = (
    "cancellation_policy customer_communication customer_signature duplicate_charge_documentation "
    "receipt refund_policy service_documentation shipping_documentation uncategorized_file"
).split()


def project(obj, kind, compact=False):
    if not isinstance(obj, dict):
        raise Failure("Expected a provider object")
    fields = LIST_FIELDS.get(kind, FIELDS[kind]) if compact else FIELDS[kind]
    result = {p.replace(".", "_"): scalar(at(obj, p)) for p in fields.split()}
    if kind == "subscription" and not compact:
        items = obj.get("items", {})
        result["items"] = [project(i, "subscription_item") for i in items.get("data", [])[:10]]
        result["items_has_more"] = bool(items.get("has_more") or len(items.get("data", [])) > 10)
    if kind == "invoice" and not compact and "lines" in obj:
        lines = obj["lines"]
        result["lines"] = [project(line, "line_item") for line in lines.get("data", [])[:10]]
        result["lines_has_more"] = bool(lines.get("has_more") or len(lines.get("data", [])) > 10)
    if kind == "credit_note" and not compact:
        rows = obj.get("refunds", [])
        result["refunds"] = [{"refund": scalar(row.get("refund")), "amount_refunded": scalar(row.get("amount_refunded"))} for row in rows[:10]]
        result["refunds_has_more"] = len(rows) > 10
    if kind == "dispute" and not compact:
        result["evidence_sha256"] = hashlib.sha256(json.dumps(obj.get("evidence", {}), sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    return result


class Client:
    def __init__(self):
        self.mode = os.environ.get("STRIPE_MODE", "test")
        self.credential = os.environ.get("STRIPE_API_KEY", "")
        if self.mode not in ("test", "live"):
            raise Failure("STRIPE_MODE must be test or live")
        fixture_credential = self.mode == "test" and self.credential == "sk_test_packtest-canary-stripe-58c9"
        if not fixture_credential and not re.fullmatch(r"[rs]k_" + self.mode + r"_[A-Za-z0-9]+", self.credential):
            raise Failure("STRIPE_API_KEY is missing or does not match STRIPE_MODE")
        self.account = os.environ.get("STRIPE_ACCOUNT_ID", "")
        if self.account and not re.fullmatch(r"acct_[A-Za-z0-9]{1,250}", self.account):
            raise Failure("Invalid STRIPE_ACCOUNT_ID")
        self.base = "https://api.stripe.com"
        self.files_base = "https://files.stripe.com"
        # Disposable model transport requires a synthetic credential; real keys
        # cannot be forwarded to any alternate host, even by misconfiguration.
        fixture = os.environ.get("STRIPE_FIXTURE_URL", "")
        if fixture:
            if not fixture_credential:
                raise Failure("Fixture transport requires the synthetic test credential")
            if not re.fullmatch(r"http://(?:stripe-api|127\.0\.0\.1):[0-9]{1,5}", fixture):
                raise Failure("Invalid fixture transport")
            self.base = self.files_base = fixture
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
        self.request_id = None

    def request(self, method, path, params=None, mutation=False, body=None, content_type=None, files=False):
        headers = {"Authorization": "Bearer " + self.credential, "Stripe-Version": VERSION}
        if self.account:
            headers["Stripe-Account"] = self.account
        if mutation:
            if arg("mode") != self.mode:
                raise Failure("Approved mode does not match STRIPE_MODE")
            if method == "POST":
                operation = arg("operation_id")
                if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,254}", operation):
                    raise Failure("A stable operation_id is required")
                headers["Idempotency-Key"] = operation
        url = (self.files_base if files else self.base) + path
        if params:
            encoded = urllib.parse.urlencode(params).encode()
            if method in ("GET", "DELETE"):
                url += "?" + encoded.decode()
            else:
                body = encoded
                content_type = "application/x-www-form-urlencoded"
        if method == "POST" and body is None:
            body = b""
            content_type = "application/x-www-form-urlencoded"
        if content_type:
            headers["Content-Type"] = content_type
        req = urllib.request.Request(url, data=body, headers=headers, method=method)
        try:
            with self.opener.open(req, timeout=25) as response:
                self.request_id = scalar(response.headers.get("Request-Id"))
                raw = response.read(MAX_RESPONSE + 1)
                if len(raw) > MAX_RESPONSE:
                    raise Failure("Provider response exceeds the 8 MiB input bound")
                data = json.loads(raw)
        except urllib.error.HTTPError as exc:
            self.request_id = scalar(exc.headers.get("Request-Id"))
            # Error text can echo the credential or submitted evidence. Return
            # only status, provider codes and request ID, never the raw body.
            code = None
            try:
                error = json.loads(exc.read(65536)).get("error", {})
                value = error.get("code", error.get("type", ""))
                if isinstance(value, str) and re.fullmatch(r"[a-z_]{1,80}", value):
                    code = value
            except (ValueError, AttributeError, TypeError):
                pass
            ambiguous = mutation and (exc.code >= 500 or exc.code in (408, 409))
            raise Failure(json.dumps({"http_status": exc.code, "code": code, "request_id": self.request_id,
                                      "outcome": "unknown; reconcile before another correction" if ambiguous else "request rejected"})) from None
        except (urllib.error.URLError, TimeoutError, OSError):
            raise Failure("Transport failed; write outcome may be unknown. Reconcile before retrying; preserve operation_id.") from None
        if not isinstance(data, dict) or "error" in data:
            raise Failure("Invalid provider response; reconcile any attempted write")
        if isinstance(data.get("livemode"), bool) and data["livemode"] != (self.mode == "live"):
            raise Failure("Provider object mode does not match STRIPE_MODE")
        return data

    def get(self, path):
        result = self.request("GET", path)
        identifier = path.rsplit("/", 1)[-1]
        if re.fullmatch(r"[a-z]+_[A-Za-z0-9]+", identifier) and result.get("id") != identifier:
            raise Failure("Provider returned a different resource than requested")
        return result


LISTS = {
    "customers": ("/v1/customers", "customer", "email created_gte created_lte"),
    "payment_intents": ("/v1/payment_intents", "payment_intent", "customer created_gte created_lte"),
    "charges": ("/v1/charges", "charge", "customer payment_intent created_gte created_lte"),
    "refunds": ("/v1/refunds", "refund", "charge payment_intent created_gte created_lte"),
    "invoices": ("/v1/invoices", "invoice", "customer subscription status created_gte created_lte"),
    "invoice_lines": ("/v1/invoices/{invoice}/lines", "line_item", ""),
    "invoice_payments": ("/v1/invoice_payments", "invoice_payment", "invoice status"),
    "subscriptions": ("/v1/subscriptions", "subscription", "customer status created_gte created_lte"),
    "subscription_items": ("/v1/subscription_items", "subscription_item", "subscription"),
    "disputes": ("/v1/disputes", "dispute", "charge payment_intent created_gte created_lte"),
    "events": ("/v1/events", "event", "type created_gte created_lte"),
    "balance_transactions": ("/v1/balance_transactions", "balance_transaction", "source payout currency type created_gte created_lte"),
    "payouts": ("/v1/payouts", "payout", "status created_gte created_lte"),
    "credit_notes": ("/v1/credit_notes", "credit_note", "customer invoice"),
    "customer_balance_transactions": ("/v1/customers/{customer}/balance_transactions", "customer_balance_transaction", ""),
    "payment_methods": ("/v1/customers/{customer}/payment_methods", "payment_method", "type"),
}


def path_for(template):
    return re.sub(r"\{([a-z_]+)\}", lambda m: urllib.parse.quote(arg(m[1]), safe=""), template)


def list_objects(client, op):
    path, kind, filters = LISTS[op]
    params = {"limit": integer("limit")}
    if arg("cursor"):
        params["starting_after"] = arg("cursor")
    for name in filters.split():
        value = arg(name)
        if value and value != "0":
            params[name.replace("_gte", "[gte]").replace("_lte", "[lte]")] = value
    if arg("created_gte", "0") != "0" and arg("created_lte", "0") != "0":
        if integer("created_gte") > integer("created_lte"):
            raise Failure("created_gte must not exceed created_lte")
    data = client.request("GET", path_for(path), params)
    rows = data.get("data")
    if not isinstance(rows, list) or len(rows) > params["limit"] or not isinstance(data.get("has_more"), bool):
        raise Failure("Invalid provider page")
    cursor = rows[-1].get("id") if rows and data["has_more"] else None
    if cursor is not None and (not isinstance(cursor, str) or len(cursor) > 255):
        raise Failure("Invalid continuation ID")
    return {"results": [project(row, kind, True) for row in rows],
            "pagination": {"has_more": data["has_more"], "next_cursor": cursor}}


def evidence_file():
    directory = os.environ.get("STRIPE_EVIDENCE_DIR", "")
    name = arg("file_name")
    if not directory or not os.path.isabs(directory):
        raise Failure("STRIPE_EVIDENCE_DIR must be an absolute staging directory")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,199}", name):
        raise Failure("Invalid evidence file name")
    directory_fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory_fd)
        with os.fdopen(fd, "rb") as stream:
            if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
                raise Failure("Evidence must be a regular file")
            data = stream.read(5_000_001)
    finally:
        os.close(directory_fd)
    if not data or len(data) > 5_000_000:
        raise Failure("Evidence must contain 1 to 5000000 bytes")
    types = [(b"%PDF-", "application/pdf"), (b"\x89PNG\r\n\x1a\n", "image/png"), (b"\xff\xd8\xff", "image/jpeg")]
    mime = next((mime for magic, mime in types if data.startswith(magic)), None)
    if not mime:
        raise Failure("Evidence must be PDF, PNG, or JPEG")
    digest = hashlib.sha256(data).hexdigest()
    if arg("expected_file_sha256") and arg("expected_file_sha256") != digest:
        raise Failure("Evidence file changed since review")
    boundary = "emisar" + uuid.uuid4().hex
    head = ("--" + boundary + '\r\nContent-Disposition: form-data; name="purpose"\r\n\r\ndispute_evidence\r\n'
            + "--" + boundary + '\r\nContent-Disposition: form-data; name="file"; filename="' + name
            + '"\r\nContent-Type: ' + mime + '\r\n\r\n').encode()
    return head + data + ("\r\n--" + boundary + "--\r\n").encode(), "multipart/form-data; boundary=" + boundary, {"file_name": name, "size": len(data), "sha256": digest, "mime_type": mime}


def run(client, op):
    if op in LISTS:
        return list_objects(client, op)
    reads = {
        "customer": ("customers", "customer"), "payment_intent": ("payment_intents", "payment_intent"),
        "charge": ("charges", "charge"), "refund": ("refunds", "refund"), "invoice": ("invoices", "invoice"),
        "invoice_payment": ("invoice_payments", "invoice_payment"), "subscription": ("subscriptions", "subscription"),
        "dispute": ("disputes", "dispute"), "event": ("events", "event"),
        "balance_transaction": ("balance_transactions", "balance_transaction"), "payout": ("payouts", "payout"),
        "credit_note": ("credit_notes", "credit_note"), "file": ("files", "file"),
    }
    if op in reads:
        collection, kind = reads[op]
        return {"result": project(client.get("/v1/" + collection + "/" + urllib.parse.quote(arg("id"), safe="")), kind)}
    if op == "balance":
        data = client.get("/v1/balance")
        return {"result": {name: [{"amount": scalar(x.get("amount")), "currency": scalar(x.get("currency"))}
                                  for x in data.get(name, [])[:100]] for name in ("available", "pending", "connect_reserved")}}
    if op == "dispute_evidence":
        data = client.get(path_for("/v1/disputes/{dispute}"))
        field = arg("field")
        if field not in TEXT_EVIDENCE + FILE_EVIDENCE:
            raise Failure("Unsupported evidence field")
        value = data.get("evidence", {}).get(field)
        if value is not None and not isinstance(value, str):
            raise Failure("Invalid evidence field")
        # One selected field, with explicit truncation rather than a raw dump.
        clipped = evidence_text(value or "")
        return {"result": {"id": data["id"], "field": field, "value": clipped,
                           "truncated": clipped != (value or "")}}
    if op == "preview_invoice":
        return {"result": project(client.request("POST", "/v1/invoices/create_preview", {"subscription": arg("subscription")}), "invoice")}
    if op in ("evidence_file_info", "upload_dispute_file"):
        body, mime, info = evidence_file()
        if op == "evidence_file_info":
            return {"result": info}
        if arg("expected_file_sha256") != info["sha256"]:
            raise Failure("Evidence file changed since review")
        return {"result": project(client.request("POST", "/v1/files", mutation=True, body=body, content_type=mime, files=True), "file")}

    path, kind, params, method = "", "", {}, "POST"
    if op == "create_refund":
        charge = client.get(path_for("/v1/charges/{charge}"))
        if charge.get("currency") != arg("currency"):
            raise Failure("Charge currency differs from the approved currency")
        path, kind = "/v1/refunds", "refund"
        params = {"charge": arg("charge"), "amount": integer("amount"), "reason": arg("reason"),
                  "reverse_transfer": str(boolean("reverse_transfer")).lower(),
                  "refund_application_fee": str(boolean("refund_application_fee")).lower()}
    elif op == "cancel_refund":
        path, kind = path_for("/v1/refunds/{refund}/cancel"), "refund"
    elif op in ("cancel_payment_intent", "capture_payment_intent"):
        path, kind = path_for("/v1/payment_intents/{payment_intent}/") + op.split("_")[0], "payment_intent"
        if op == "cancel_payment_intent":
            params = {"cancellation_reason": arg("reason")}
        else:
            intent = client.get(path_for("/v1/payment_intents/{payment_intent}"))
            if intent.get("currency") != arg("currency"):
                raise Failure("Payment currency differs from the approved currency")
            params = {"amount_to_capture": integer("amount"), "final_capture": "true"}
    elif op in ("pay_invoice", "record_invoice_payment", "send_invoice", "finalize_invoice", "void_invoice", "write_off_invoice"):
        suffix = {"pay_invoice": "pay", "record_invoice_payment": "pay", "send_invoice": "send", "finalize_invoice": "finalize",
                  "void_invoice": "void", "write_off_invoice": "mark_uncollectible"}[op]
        path, kind = path_for("/v1/invoices/{invoice}/") + suffix, "invoice"
        if op in ("pay_invoice", "record_invoice_payment"):
            invoice = client.get(path_for("/v1/invoices/{invoice}"))
            # A completed retry still reaches Stripe's idempotency store. For an
            # open invoice, the approved balance and currency must still match.
            if invoice.get("currency") != arg("currency") or (invoice.get("status") != "paid" and invoice.get("amount_remaining") != integer("expected_amount")):
                raise Failure("Invoice balance or currency changed; investigate before collecting")
            params = {"paid_out_of_band": str(op == "record_invoice_payment").lower(), "forgive": "false"}
            if arg("payment_method"):
                params["payment_method"] = arg("payment_method")
        elif op == "finalize_invoice":
            params = {"auto_advance": "false"}
    elif op in ("schedule_subscription_cancel", "undo_subscription_cancel", "pause_collection", "resume_collection", "cancel_subscription", "resume_subscription"):
        path, kind = path_for("/v1/subscriptions/{subscription}"), "subscription"
        if op in ("schedule_subscription_cancel", "undo_subscription_cancel"):
            params = {"cancel_at_period_end": str(op == "schedule_subscription_cancel").lower()}
        elif op == "pause_collection":
            params = {"pause_collection[behavior]": arg("behavior")}
            if arg("resumes_at") != "0":
                params["pause_collection[resumes_at]"] = integer("resumes_at")
        elif op == "resume_collection":
            params = {"pause_collection": ""}
        elif op == "cancel_subscription":
            method = "DELETE"
            params = {"invoice_now": str(boolean("invoice_now")).lower(), "prorate": str(boolean("prorate")).lower()}
        else:
            path += "/resume"
            params = {"billing_cycle_anchor": arg("billing_cycle_anchor"), "proration_behavior": "none"}
    elif op == "credit_customer_balance":
        path, kind = path_for("/v1/customers/{customer}/balance_transactions"), "customer_balance_transaction"
        params = {"amount": -integer("amount"), "currency": arg("currency"), "description": arg("description")}
    elif op in ("stage_dispute_text", "stage_dispute_file", "submit_dispute_evidence", "accept_dispute"):
        path, kind = path_for("/v1/disputes/{dispute}"), "dispute"
        if op == "accept_dispute":
            path += "/close"
        elif op == "submit_dispute_evidence":
            current = client.get(path)
            details = current.get("evidence_details", {})
            if not details.get("has_evidence"):
                raise Failure("No staged evidence to submit")
            observed = hashlib.sha256(json.dumps(current.get("evidence", {}), sort_keys=True, separators=(",", ":")).encode()).hexdigest()
            if observed != arg("expected_evidence_sha256"):
                raise Failure("Evidence changed since review; investigate before submitting")
            params = {"submit": "true"}
        else:
            allowed = TEXT_EVIDENCE if op == "stage_dispute_text" else FILE_EVIDENCE
            if arg("field") not in allowed:
                raise Failure("Unsupported evidence field")
            params = {"submit": "false", "evidence[" + arg("field") + "]": arg("content" if op == "stage_dispute_text" else "file")}
    elif op == "void_credit_note":
        path, kind = path_for("/v1/credit_notes/{credit_note}/void"), "credit_note"
    elif op in ("preview_credit_note", "create_credit_note"):
        path, kind = "/v1/credit_notes", "credit_note"
        params = {"invoice": arg("invoice"), "amount": integer("amount"), "reason": arg("reason"),
                  "credit_amount": integer("credit_amount"), "refund_amount": integer("refund_amount"),
                  "out_of_band_amount": integer("out_of_band_amount")}
        existing = integer("existing_refund_amount")
        if bool(arg("existing_refund")) != bool(existing):
            raise Failure("Existing refund ID and its allocation must be supplied together")
        if existing:
            params.update({"refunds[0][refund]": arg("existing_refund"), "refunds[0][amount_refunded]": existing, "refunds[0][type]": "refund"})
        if integer("credit_amount") + integer("refund_amount") + integer("out_of_band_amount") + existing > integer("amount"):
            raise Failure("Credit dispositions exceed the credit note amount")
        if op == "preview_credit_note":
            return {"result": project(client.request("GET", path + "/preview", params), kind)}
        invoice = client.get(path_for("/v1/invoices/{invoice}"))
        if invoice.get("currency") != arg("currency"):
            raise Failure("Invoice currency differs from the approved currency")
        params["email_type"] = "none"
    else:
        raise Failure("Unknown Stripe operation")
    return {"result": project(client.request(method, path, params, mutation=True), kind)}


def main():
    client = Client()
    result = run(client, sys.argv[1])
    result["context"] = {"mode": client.mode, "connected_account": client.account or None,
                         "api_version": VERSION, "request_id": client.request_id}
    encoded = json.dumps(result, ensure_ascii=False, separators=(",", ":"))
    if len(encoded.encode()) > 60000:
        raise Failure("Output exceeds the bounded result; narrow the read. Reconcile any attempted write.")
    print(encoded)


if __name__ == "__main__":
    try:
        main()
    except Failure as exc:
        print(str(exc), file=sys.stderr)
        sys.exit(1)
    except (ValueError, TypeError, KeyError, IndexError, OSError, RecursionError):
        print("Invalid input or provider response; reconcile any attempted write before retrying", file=sys.stderr)
        sys.exit(1)
