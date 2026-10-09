"""Stateful Stripe REST model, independent of the packaged client."""
import copy
import json
from email.parser import BytesParser
from email.policy import default
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

SEED = json.loads(Path(__file__).with_name("seed.json").read_text())
STATE = copy.deepcopy(SEED)
WRITES = 0
REQUESTS = 0
REPLAYS = {}
CREDIT_NOTE_REQUESTS = []
CREDIT_NOTE_REFUNDS = []
ALLOCATION_FIELDS = ("credit_amount", "refund_amount", "out_of_band_amount")
CREDIT_NOTE_FIELDS = {"invoice", "amount", "reason", "email_type", *ALLOCATION_FIELDS,
                      "refunds[0][refund]", "refunds[0][amount_refunded]", "refunds[0][type]"}
COLLECTIONS = {"customers": "customer", "payment_intents": "payment_intent", "charges": "charge", "refunds": "refund",
               "invoices": "invoice", "invoice_payments": "invoice_payment", "subscriptions": "subscription", "subscription_items": "subscription_item",
               "disputes": "dispute", "events": "event", "balance_transactions": "balance_transaction", "payouts": "payout",
               "credit_notes": "credit_note", "files": "file"}
FILTERS = {"customers": {"email"}, "payment_intents": {"customer"}, "charges": {"customer", "payment_intent"},
           "refunds": {"charge", "payment_intent"}, "invoices": {"customer", "subscription", "status"},
           "invoice_payments": {"invoice", "status"}, "subscriptions": {"customer", "status"}, "subscription_items": {"subscription"},
           "disputes": {"charge", "payment_intent"}, "events": {"type"}, "balance_transactions": {"source", "payout", "currency", "type"},
           "payouts": {"status"}, "credit_notes": {"customer", "invoice"}}


def credit_note(params):
    """Validate decoded provider parameters independently of the client."""
    if set(params) - CREDIT_NOTE_FIELDS:
        raise ValueError("parameter_unknown")
    invoice = STATE["invoice"]
    if params.get("invoice") != invoice["id"]:
        raise ValueError("resource_missing")
    if invoice["status"] not in ("open", "paid"):
        raise ValueError("invoice_not_finalized")
    amount = int(params.get("amount", "0"))
    if amount <= 0:
        raise ValueError("parameter_invalid_integer")
    allocations = {}
    for field in ALLOCATION_FIELDS:
        allocations[field] = int(params.get(field, "0"))
        # Recorded live regression: omission and an explicit zero differ.
        if field in params and allocations[field] <= 0:
            raise ValueError("parameter_invalid_integer")
    linked = 0
    refund_fields = {"refunds[0][refund]", "refunds[0][amount_refunded]", "refunds[0][type]"}
    if set(params) & refund_fields:
        if not refund_fields <= set(params):
            raise ValueError("invalid_refund_allocation")
        linked = int(params["refunds[0][amount_refunded]"])
        if (params["refunds[0][refund]"] != STATE["refund"]["id"] or params["refunds[0][type]"] != "refund"
                or linked <= 0 or linked > STATE["refund"]["amount"]):
            raise ValueError("invalid_refund_allocation")
    pre_payment = min(amount, invoice["amount_remaining"])
    post_payment = amount - pre_payment
    if sum(allocations.values()) + linked != post_payment:
        raise ValueError("credit_note_invalid_dispositions")
    note = copy.deepcopy(SEED["credit_note"])
    note.update(invoice=invoice["id"], customer=invoice["customer"], currency=invoice["currency"],
                amount=amount, reason=params.get("reason"), status="issued", voided_at=None,
                pre_payment_amount=pre_payment, post_payment_amount=post_payment,
                type="post_payment" if post_payment else "pre_payment",
                out_of_band_amount=allocations["out_of_band_amount"] or None,
                customer_balance_transaction="cbtxn_creditnote" if allocations["credit_amount"] else None,
                refunds=[])
    if linked:
        note["refunds"].append({"refund": params["refunds[0][refund]"], "amount_refunded": linked})
    if allocations["refund_amount"]:
        note["refunds"].append({"refund": "re_creditnote", "amount_refunded": allocations["refund_amount"]})
    return note


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def send(self, value, code=200):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Request-Id", "req_fixture")
        self.end_headers()
        self.wfile.write(json.dumps(value).encode())

    def do_GET(self):
        global REQUESTS
        parsed = urlsplit(self.path)
        if parsed.path == "/health":
            return self.send({"ok": True})
        if parsed.path == "/probe":
            return self.send({"state": STATE, "writes": WRITES, "requests": REQUESTS,
                              "credit_note_requests": CREDIT_NOTE_REQUESTS, "credit_note_refunds": CREDIT_NOTE_REFUNDS})
        self.handle_api("GET")

    def do_POST(self):
        if self.path.startswith("/arrange/"):
            scenario = self.path.rsplit("/", 1)[-1]
            if scenario == "draft_invoice":
                STATE["invoice"]["status"] = "draft"
            elif scenario == "actionable_refund":
                STATE["refund"]["status"] = "requires_action"
            elif scenario == "paused_subscription":
                STATE["subscription"]["status"] = "paused"
            elif scenario == "scheduled_cancel":
                STATE["subscription"]["cancel_at_period_end"] = True
            elif scenario == "paused_collection":
                STATE["subscription"]["pause_collection"] = {"behavior": "keep_as_draft"}
            elif scenario == "paid_invoice":
                STATE["invoice"].update(status="paid", amount_paid=1200, amount_remaining=0)
            elif scenario == "partially_paid_invoice":
                STATE["invoice"].update(status="open", amount_paid=900, amount_remaining=300)
            return self.send({"arranged": scenario})
        self.handle_api("POST")

    def do_DELETE(self):
        self.handle_api("DELETE")

    def handle_api(self, method):
        global WRITES, REQUESTS
        REQUESTS += 1
        if self.headers.get("Authorization") != "Bearer sk_test_packtest-canary-stripe-58c9" or self.headers.get("Stripe-Version") != "2026-08-26.dahlia":
            return self.send({"error": {"code": "invalid_api_key"}}, 401)
        account = self.headers.get("Stripe-Account")
        if account == "acct_denied":
            return self.send({"error": {"code": "permission_denied", "message": "packtest-canary-private-metadata-120a"}}, 403)
        if account == "acct_redirect":
            self.send_response(302)
            self.send_header("Location", "http://127.0.0.1:1/leak")
            self.end_headers()
            return
        parsed = urlsplit(self.path)
        parts = parsed.path.strip("/").split("/")
        params = {k: v[0] for k, v in parse_qs(parsed.query, keep_blank_values=True).items()}
        raw = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        if method == "POST" and self.headers.get("Content-Type", "").startswith("application/x-www-form-urlencoded"):
            params = {k: v[0] for k, v in parse_qs(raw.decode(), keep_blank_values=True).items()}
        if len(parts) < 2 or parts[0] != "v1":
            return self.send({"error": {"code": "resource_missing"}}, 404)
        collection = parts[1]
        kind = COLLECTIONS.get(collection)
        if collection == "credit_notes" and (parts == ["v1", "credit_notes"] or parts[-1] == "preview"):
            # Probe only billing fields, never credentials or arbitrary bodies.
            CREDIT_NOTE_REQUESTS.append({"method": method, "path": parsed.path,
                                         "params": {k: v for k, v in params.items() if k in CREDIT_NOTE_FIELDS}})
        if any("missing" in part for part in parts):
            return self.send({"error": {"code": "resource_missing"}}, 404)
        if collection == "balance" and method == "GET":
            return self.send(STATE["balance"])
        if not kind:
            return self.send({"error": {"code": "resource_missing"}}, 404)
        preview = (collection == "invoices" and parts[-1] == "create_preview") or (collection == "credit_notes" and parts[-1] == "preview")
        if preview:
            if collection == "invoices" and method != "POST" or collection == "credit_notes" and method != "GET":
                return self.send({"error": {"code": "invalid_request"}}, 400)
            obj = copy.deepcopy(STATE[kind])
            if collection == "invoices":
                obj["id"] = "upcoming_in_fixture"
            else:
                try:
                    obj = credit_note(params)
                except ValueError as exc:
                    return self.send({"error": {"code": str(exc), "message": "packtest-canary-private-metadata-120a"}}, 400)
            return self.send(obj)
        if method == "GET":
            nested = len(parts) == 4
            if nested:
                kind = {"lines": "line_item", "payment_methods": "payment_method", "balance_transactions": "customer_balance_transaction"}.get(parts[3])
                if kind is None:
                    return self.send({"error": {"code": "resource_missing"}}, 404)
            if len(parts) == 2 or nested:
                allowed = FILTERS.get(collection, set()) | {"limit", "starting_after", "created[gte]", "created[lte]"}
                if nested:
                    allowed |= {"type"}
                if set(params) - allowed:
                    return self.send({"error": {"code": "parameter_unknown"}}, 400)
                if account == "acct_empty" or (params.get("email") and params["email"] != STATE["customer"]["email"]):
                    return self.send({"object": "list", "data": [], "has_more": False})
                limit = int(params.get("limit", 10))
                start = 10 if params.get("starting_after", "").endswith("_9") else 0
                rows = []
                for i in range(start, min(start + limit, 12)):
                    obj = copy.deepcopy(STATE[kind])
                    if i:
                        obj["id"] += "_" + str(i)
                    if account == "acct_maximum":
                        # Long provider-controlled text, including JSON escapes.
                        for key in ("name", "email", "description"):
                            obj[key] = '\\"' * 10000
                    rows.append(obj)
                return self.send({"object": "list", "data": rows, "has_more": start + limit < 12})
            obj = copy.deepcopy(STATE[kind])
            obj["id"] = parts[2]
            return self.send(obj)
        operation_id = self.headers.get("Idempotency-Key")
        if method == "POST" and not operation_id:
            return self.send({"error": {"code": "missing_idempotency"}}, 400)
        fingerprint = [method, parsed.path, params]
        if operation_id in REPLAYS:
            old, result = REPLAYS[operation_id]
            if old != fingerprint:
                return self.send({"error": {"code": "idempotency_key_in_use"}}, 409)
            return self.send(result)
        obj = STATE[kind]
        suffix = parts[-1]
        if collection == "refunds" and len(parts) == 2:
            if params.get("charge") != "ch_fixture" or int(params.get("amount", "0")) <= 0:
                return self.send({"error": {"code": "invalid_request"}}, 400)
            obj.update(amount=int(params["amount"]), reason=params["reason"], status="succeeded")
            STATE["charge"]["amount_refunded"] += obj["amount"]
        elif collection == "refunds" and suffix == "cancel":
            if obj["status"] != "requires_action":
                return self.send({"error": {"code": "refund_not_cancelable"}}, 400)
            obj["status"] = "canceled"
        elif collection == "payment_intents" and suffix in ("cancel", "capture"):
            obj["status"] = "canceled" if suffix == "cancel" else "succeeded"
            if suffix == "capture":
                if params.get("final_capture") != "true":
                    return self.send({"error": {"code": "invalid_request"}}, 400)
                obj["amount_received"] = int(params["amount_to_capture"])
                obj["amount_capturable"] = 0
        elif collection == "invoices":
            if suffix == "finalize" and obj["status"] != "draft":
                return self.send({"error": {"code": "invoice_not_draft"}}, 400)
            status = {"pay": "paid", "send": "open", "finalize": "open", "void": "void", "mark_uncollectible": "uncollectible"}.get(suffix)
            if not status or suffix == "finalize" and params.get("auto_advance") != "false":
                return self.send({"error": {"code": "invalid_request"}}, 400)
            obj["status"] = status
            obj["last_operation"] = suffix
            if suffix == "pay":
                obj.update(amount_paid=1200, amount_remaining=0, paid_out_of_band=params["paid_out_of_band"] == "true")
        elif collection == "subscriptions":
            if method == "DELETE":
                obj["status"] = "canceled"
            elif suffix == "resume":
                if obj["status"] != "paused":
                    return self.send({"error": {"code": "subscription_not_paused"}}, 400)
                obj["status"] = "active"
                obj["resumed"] = True
            elif "cancel_at_period_end" in params:
                obj["cancel_at_period_end"] = params["cancel_at_period_end"] == "true"
            elif "pause_collection[behavior]" in params:
                obj["pause_collection"] = {"behavior": params["pause_collection[behavior]"]}
            elif params.get("pause_collection") == "":
                obj["pause_collection"] = None
            else:
                return self.send({"error": {"code": "invalid_request"}}, 400)
        elif collection == "customers" and suffix == "balance_transactions":
            kind, obj = "customer_balance_transaction", STATE["customer_balance_transaction"]
            obj.update(amount=int(params["amount"]), ending_balance=int(params["amount"]), currency=params["currency"])
            STATE["customer"]["balance"] = obj["amount"]
        elif collection == "disputes":
            if suffix == "close":
                obj["status"] = "lost"
            elif params.get("submit") == "true":
                obj["status"] = "under_review"
                obj["evidence_details"]["submission_count"] += 1
            elif params.get("submit") == "false":
                for key, value in params.items():
                    if key.startswith("evidence["):
                        obj["evidence"][key[9:-1]] = value
            else:
                return self.send({"error": {"code": "missing_submit"}}, 400)
        elif collection == "files":
            message = BytesParser(policy=default).parsebytes(("Content-Type: " + self.headers["Content-Type"] + "\r\n\r\n").encode() + raw)
            fields = {p.get_param("name", header="content-disposition"): p for p in message.iter_parts()}
            if fields["purpose"].get_payload(decode=True) != b"dispute_evidence":
                return self.send({"error": {"code": "invalid_request"}}, 400)
            obj["size"] = len(fields["file"].get_payload(decode=True))
        elif collection == "credit_notes":
            if suffix == "void":
                obj["status"] = "void"
            else:
                if params.get("email_type") != "none":
                    return self.send({"error": {"code": "invalid_request"}}, 400)
                # Replay lookup above must precede state-dependent validation.
                try:
                    note = credit_note(params)
                except ValueError as exc:
                    return self.send({"error": {"code": str(exc), "message": "packtest-canary-private-metadata-120a"}}, 400)
                obj.clear()
                obj.update(note)
                invoice = STATE["invoice"]
                invoice["amount_remaining"] -= note["pre_payment_amount"]
                invoice["amount_due"] -= note["pre_payment_amount"]
                STATE["customer"]["balance"] -= int(params.get("credit_amount", "0"))
                if "refund_amount" in params:
                    CREDIT_NOTE_REFUNDS.append({"id": "re_creditnote", "amount": int(params["refund_amount"])})
                    STATE["charge"]["amount_refunded"] += int(params["refund_amount"])
        else:
            return self.send({"error": {"code": "invalid_request"}}, 400)
        WRITES += 1
        obj["correction_applied"] = True
        result = copy.deepcopy(obj)
        if operation_id:
            REPLAYS[operation_id] = (fingerprint, result)
        if account == "acct_ambiguous":
            return self.send({"error": {"code": "api_error", "message": "packtest-canary-private-metadata-120a"}}, 500)
        return self.send(result)


HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
