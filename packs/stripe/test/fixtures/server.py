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
COLLECTIONS = {"customers": "customer", "payment_intents": "payment_intent", "charges": "charge", "refunds": "refund",
               "invoices": "invoice", "invoice_payments": "invoice_payment", "subscriptions": "subscription", "subscription_items": "subscription_item",
               "disputes": "dispute", "events": "event", "balance_transactions": "balance_transaction", "payouts": "payout",
               "credit_notes": "credit_note", "files": "file"}
FILTERS = {"customers": {"email"}, "payment_intents": {"customer"}, "charges": {"customer", "payment_intent"},
           "refunds": {"charge", "payment_intent"}, "invoices": {"customer", "subscription", "status"},
           "invoice_payments": {"invoice", "status"}, "subscriptions": {"customer", "status"}, "subscription_items": {"subscription"},
           "disputes": {"charge", "payment_intent"}, "events": {"type"}, "balance_transactions": {"source", "payout", "currency", "type"},
           "payouts": {"status"}, "credit_notes": {"customer", "invoice"}}


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
            return self.send({"state": STATE, "writes": WRITES, "requests": REQUESTS})
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
                obj.update(amount=int(params["amount"]), status="issued")
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
