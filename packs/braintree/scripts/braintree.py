#!/usr/bin/env python3
"""Bounded Braintree GraphQL billing operations, version 2026-09-08.

Selections and variable shapes are authored here, never supplied by callers.
Official schema: braintree/graphql-api commit 4c8d397849df33128d5bace6555b2516c129b28e.
"""

import base64
import hashlib
import json
import os
import re
import stat
import sys
import urllib.error
import urllib.request
import uuid
from decimal import Decimal


class Failure(Exception):
    pass


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def arg(name, default=""):
    return os.environ.get("ARG_" + name.upper(), default)


def leaves(names):
    return dict.fromkeys(names.split())


MONEY = leaves("value currencyCode")
IDENTITY = leaves("id legacyId")
PAYMENT = {**IDENTITY, **leaves("createdAt status orderId merchantAccountId"), "amount": MONEY}
PROCESSOR = leaves("legacyCode cvvResponse avsPostalCodeResponse avsStreetAddressResponse")
HISTORY = {**leaves("__typename status timestamp source terminal"), "amount": MONEY,
           "... on GatewayRejectedEvent": {"gatewayRejectionReason": None, "processorResponse": PROCESSOR},
           "... on ProcessorDeclinedEvent": {"declineType": None, "processorResponse": PROCESSOR}}
EVIDENCE = leaves("id legacyId category createdAt sentToProcessorAt")
TIMELINE = leaves("createdAt updatedAt firstBillingDate nextBillingDate billingPeriodStartDate billingPeriodEndDate paidThroughDate")
SUBSCRIPTION = {**IDENTITY, **leaves("status price balance planId paymentMethodId merchantAccountId failureCount daysPastDue nextBillingPeriodAmount currentBillingCycle numberOfBillingCycles"), "timeline": TIMELINE}
DISPUTE = {**IDENTITY, **leaves("status type createdAt responseDeadline replyByDate remainingFileEvidenceStorage"), "amountDisputed": MONEY, "amountWon": MONEY, "transaction": IDENTITY}
CARD = {"... on CreditCardDetails": leaves("brandCode last4 expirationMonth expirationYear")}
PAYMENT_METHOD = {**IDENTITY, **leaves("usage createdAt"), "customer": IDENTITY, "details": {"__typename": None, **CARD}}
SELECT = {
    "transaction": {**PAYMENT, "customer": IDENTITY, "paymentMethod": IDENTITY,
                    "processorAuthorizationResponse": PROCESSOR, "processorSettlementResponse": leaves("legacyCode achReturnCode"),
                    "statusHistory": HISTORY, "refunds": PAYMENT, "disputes": DISPUTE,
                    "disbursementDetails": {**leaves("date exchangeRate fundsHeld"), "amount": MONEY},
                    **leaves("retried upcomingRetryDate"), "retriedParentTransaction": IDENTITY},
    "refund": {**PAYMENT, "refundedTransaction": IDENTITY, "customer": IDENTITY,
               "processorAuthorizationResponse": PROCESSOR, "statusHistory": HISTORY,
               "disbursementDetails": {**leaves("date exchangeRate fundsHeld"), "amount": MONEY}},
    "customer": {**IDENTITY, **leaves("createdAt email firstName lastName company"), "defaultPaymentMethod": IDENTITY},
    "payment_method": PAYMENT_METHOD,
    "subscription": {**SUBSCRIPTION, "addOns": leaves("addOnId amount quantity numberOfBillingCycles"),
                     "discounts": leaves("discountId amount quantity numberOfBillingCycles")},
    "dispute": {**DISPUTE, "evidence": EVIDENCE, "statusHistory": leaves("status timestamp effectiveDate disbursementDate"),
                "processorResponse": leaves("reasonCode reasonDescription")},
    "plan": {**IDENTITY, **leaves("name billingFrequency billingDayOfMonth numberOfBillingCycles createdAt updatedAt"), "price": MONEY},
}
TYPES = {"transaction": "Transaction", "refund": "Refund", "customer": "Customer", "payment_method": "PaymentMethod",
         "subscription": "RecurringBillingSubscription", "dispute": "Dispute", "plan": "RecurringBillingSubscriptionPlan"}
SEARCH = {"transactions": ("TransactionSearchInput", "transaction", PAYMENT), "refunds": ("RefundSearchInput", "refund", PAYMENT),
          "customers": ("CustomerSearchInput", "customer", SELECT["customer"]),
          "disputes": ("DisputeSearchInput", "dispute", DISPUTE),
          "subscriptions": ("RecurringBillingSubscriptionSearchInput", "subscription", SUBSCRIPTION)}


def selection(shape):
    return " ".join(key + (" { " + selection(child) + " }" if child else "") for key, child in shape.items())


def project(value, shape, array_limit=5):
    if value is None:
        return None
    if isinstance(value, list):
        return [project(item, shape, array_limit) for item in value[:array_limit]]
    if shape is None:
        if isinstance(value, str):
            return "".join(c if ord(c) >= 32 else " " for c in value)[:256]
        if isinstance(value, (bool, int, float)):
            return value
        raise Failure("Unexpected provider scalar")
    if not isinstance(value, dict):
        raise Failure("Unexpected provider object")
    result = {}
    for key, child in shape.items():
        if key.startswith("... on "):
            if value.get("__typename") == key[7:]:
                result.update(project(value, child, array_limit))
            continue
        result[key] = project(value.get(key), child, array_limit)
        if isinstance(value.get(key), list):
            result[key + "_has_more"] = len(value[key]) > array_limit
    return result


def evidence_digest(rows):
    return hashlib.sha256(json.dumps(rows, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


class Client:
    def __init__(self):
        self.mode = os.environ.get("BRAINTREE_ENVIRONMENT", "sandbox")
        if self.mode not in ("sandbox", "production"):
            raise Failure("BRAINTREE_ENVIRONMENT must be sandbox or production")
        public = os.environ.get("BRAINTREE_PUBLIC_KEY", "")
        private = os.environ.get("BRAINTREE_PRIVATE_KEY", "")
        if not public or not private or not re.fullmatch(r"[A-Za-z0-9_-]{1,256}", public) or not re.fullmatch(r"[A-Za-z0-9_-]{1,256}", private):
            raise Failure("Braintree API credentials are missing or invalid")
        self.authorization = "Basic " + base64.b64encode((public + ":" + private).encode()).decode()
        self.url = "https://payments.sandbox.braintree-api.com/graphql" if self.mode == "sandbox" else "https://payments.braintree-api.com/graphql"
        fixture = os.environ.get("BRAINTREE_FIXTURE_URL", "")
        if fixture:
            if (public, private, self.mode) != ("packtest-canary-braintree-public-749a", "packtest-canary-braintree-private-28ac", "sandbox"):
                raise Failure("Fixture transport requires synthetic sandbox credentials")
            if not re.fullmatch(r"http://(?:braintree-api|127\.0\.0\.1):[0-9]{1,5}/graphql", fixture):
                raise Failure("Invalid fixture transport")
            self.url = fixture
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
        self.request_id = None

    def request(self, query, variables, mutation=False, upload=None):
        if mutation and arg("environment") != self.mode:
            raise Failure("Approved environment differs from BRAINTREE_ENVIRONMENT")
        payload = {"query": query, "variables": variables}
        body = json.dumps(payload).encode()
        content_type = "application/json"
        if upload:
            name, data, mime = upload
            payload["variables"]["file"] = None
            boundary = "emisar" + uuid.uuid4().hex
            parts = []
            for part_name, content in (("operations", json.dumps(payload)), ("map", json.dumps({"file_to_upload": "variables.file"}))):
                parts.append(("--" + boundary + '\r\nContent-Disposition: form-data; name="' + part_name + '"\r\nContent-Type: application/json\r\n\r\n' + content + "\r\n").encode())
            parts.append(("--" + boundary + '\r\nContent-Disposition: form-data; name="file_to_upload"; filename="' + name + '"\r\nContent-Type: ' + mime + "\r\n\r\n").encode())
            body = b"".join(parts) + data + ("\r\n--" + boundary + "--\r\n").encode()
            content_type = "multipart/form-data; boundary=" + boundary
        request = urllib.request.Request(self.url, data=body, headers={"Authorization": self.authorization,
                                            "Braintree-Version": "2026-09-08", "Content-Type": content_type})
        try:
            with self.opener.open(request, timeout=60) as response:
                raw = response.read(8 * 1024 * 1024 + 1)
                if len(raw) > 8 * 1024 * 1024:
                    raise Failure("Provider response exceeds the 8 MiB input bound")
                result = json.loads(raw)
        except urllib.error.HTTPError as exc:
            raise Failure("Braintree HTTP " + str(exc.code) + "; reconcile any attempted write before retrying") from None
        except (urllib.error.URLError, TimeoutError, OSError):
            raise Failure("Transport failed; write outcome may be unknown. Reconcile before retrying; preserve operation_id where supported.") from None
        if not isinstance(result, dict):
            raise Failure("Invalid GraphQL response")
        self.request_id = project(result.get("extensions", {}).get("requestId"), None)
        if result.get("errors"):
            codes = []
            for error in result["errors"][:10]:
                code = error.get("extensions", {}).get("errorClass", "")
                if isinstance(code, str) and re.fullmatch(r"[A-Z_]{1,80}", code):
                    codes.append(code)
            raise Failure(json.dumps({"error": "GraphQL request failed; reconcile any attempted write", "classes": codes, "request_id": self.request_id}))
        if not isinstance(result.get("data"), dict):
            raise Failure("GraphQL response has no data; reconcile any attempted write")
        return result["data"]

    def node(self, kind, identifier, shape=None):
        shape = shape or SELECT[kind]
        query = "query BillingNode($id:ID!){ node(id:$id){ __typename ... on " + TYPES[kind] + " { " + selection(shape) + " } } }"
        obj = self.request(query, {"id": identifier}).get("node")
        if not isinstance(obj, dict) or obj.get("__typename") != TYPES[kind] or obj.get("id") != identifier:
            raise Failure("Object not found or resource type differs from the requested action")
        return obj

    def mutate(self, name, input_type, values, shape, upload=None):
        query = "mutation BillingCorrection($input:" + input_type + "!){ " + name + "(input:$input){ " + selection(shape) + " } }"
        result = self.request(query, {"input": values}, mutation=True, upload=upload).get(name)
        if not isinstance(result, dict):
            raise Failure("Missing mutation result; reconcile provider state")
        for resource in ("transaction", "refund"):
            obj = result.get(resource)
            if isinstance(obj, dict) and obj.get("status") in ("PROCESSOR_DECLINED", "GATEWAY_REJECTED", "FAILED", "SETTLEMENT_DECLINED"):
                raise Failure(json.dumps({"error": "Payment correction was declined", "status": obj["status"], "id": project(obj.get("id"), None)}))
        return project(result, shape)


def page(connection, shape):
    if not isinstance(connection, dict) or not isinstance(connection.get("edges"), list) or len(connection["edges"]) > int(arg("limit")):
        raise Failure("Invalid provider page")
    info = connection.get("pageInfo", {})
    cursor = info.get("endCursor")
    if not isinstance(info.get("hasNextPage"), bool) or (cursor is not None and (not isinstance(cursor, str) or len(cursor) > 2048)):
        raise Failure("Invalid provider continuation")
    return {"results": [project(edge["node"], shape) for edge in connection["edges"]],
            "pagination": {"has_more": info["hasNextPage"], "next_cursor": cursor if info["hasNextPage"] else None}}


def connection_query(field, shape):
    return field + " { edges { node { " + selection(shape) + " } } pageInfo { hasNextPage endCursor } }"


def search(client, op):
    input_type, kind, shape = SEARCH[op]
    values = {}
    for name, target in (("email", "email"), ("order_id", "orderId"), ("merchant_account_id", "merchantAccountId"), ("plan_id", "planId"), ("settlement_batch_id", "settlementBatchId")):
        if arg(name):
            values[target] = {"is": arg(name)}
    if arg("status"):
        values["status"] = [arg("status")] if op == "subscriptions" else {"is": arg("status")}
    if arg("customer_id"):
        values["customer"] = {"id": {"is": arg("customer_id")}}
    if arg("transaction_id"):
        values["transaction"] = {"transactionId": {"is": arg("transaction_id")}}
    if arg("created_from") or arg("created_to"):
        values["createdAt"] = {key: arg(name) for name, key in (("created_from", "greaterThanOrEqualTo"), ("created_to", "lessThanOrEqualTo")) if arg(name)}
    if arg("currency"):
        values["amount"] = {"currencyCode": {"is": arg("currency")}}
    field = "recurringBillingSubscriptions" if op == "subscriptions" else op
    query = "query BillingSearch($input:" + input_type + "!,$first:Int!,$after:String){ " + connection_query(field + "(input:$input,first:$first,after:$after)", shape) + " }"
    return page(client.request(query, {"input": values, "first": int(arg("limit")), "after": arg("cursor") or None})[field], shape)


def file_bytes():
    directory, name = os.environ.get("BRAINTREE_EVIDENCE_DIR", ""), arg("file_name")
    if not os.path.isabs(directory) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,199}", name):
        raise Failure("Evidence requires BRAINTREE_EVIDENCE_DIR and a regular file basename")
    directory_fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory_fd)
        with os.fdopen(fd, "rb") as stream:
            if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
                raise Failure("Evidence must be a regular file")
            data = stream.read(4_000_001)
    finally:
        os.close(directory_fd)
    if not data or len(data) > 4_000_000:
        raise Failure("Evidence must contain 1 to 4000000 bytes")
    mime = next((m for magic, m in ((b"%PDF-", "application/pdf"), (b"\x89PNG\r\n\x1a\n", "image/png"), (b"\xff\xd8\xff", "image/jpeg")) if data.startswith(magic)), None)
    if not mime:
        raise Failure("Evidence must be PDF, PNG, or JPEG")
    return name, data, mime


def run(client, op):
    if op in SEARCH:
        return search(client, op)
    if op == "dispute_evidence_text":
        shape = {"id": None, "evidence": {**EVIDENCE, "__typename": None, "... on DisputeTextEvidence": {"content": None}}}
        obj = client.node("dispute", arg("dispute_id"), shape)
        row = next((row for row in obj.get("evidence", []) if row.get("id") == arg("evidence_id")), None)
        if not row or row.get("__typename") != "DisputeTextEvidence":
            raise Failure("Text evidence item not found on this dispute")
        content = row.get("content") or ""
        clipped = content[:20000]
        while len(json.dumps(clipped, ensure_ascii=False).encode()) > 40000:
            clipped = clipped[:len(clipped) * 9 // 10]
        return {"result": {"id": row["id"], "content": clipped, "truncated": clipped != content}}
    if op in SELECT:
        obj = client.node(op, arg("id"))
        result = project(obj, SELECT[op])
        if op == "dispute":
            result["evidence_sha256"] = evidence_digest(obj.get("evidence", []))
        return {"result": result}
    if op == "account":
        shape = leaves("id status companyName timezone")
        return {"result": project(client.request("query BillingAccount{viewer{merchant{" + selection(shape) + "}}}", {})["viewer"]["merchant"], shape)}
    if op == "merchant_accounts":
        shape = leaves("id currencyCode status isDefault")
        query = "query BillingAccounts($first:Int!,$after:String){viewer{merchant{" + connection_query("merchantAccounts(first:$first,after:$after)", shape) + "}}}"
        return page(client.request(query, {"first": int(arg("limit")), "after": arg("cursor") or None})["viewer"]["merchant"]["merchantAccounts"], shape)
    if op == "resolve_id":
        data = client.request("query BillingResolve($input:IdsFromLegacyIdsInput!){idsFromLegacyIds(input:$input)}",
                              {"input": {"ids": [{"legacyId": arg("legacy_id"), "type": arg("resource_type")}]}})
        return {"result": {"id": data["idsFromLegacyIds"][0], "legacy_id": arg("legacy_id"), "resource_type": arg("resource_type")}}
    if op in ("customer_payment_methods", "customer_transactions"):
        field, shape = ("paymentMethods", PAYMENT_METHOD) if op == "customer_payment_methods" else ("transactions", PAYMENT)
        query = "query BillingCustomerPage($id:ID!,$first:Int!,$after:String){node(id:$id){... on Customer{" + connection_query(field + "(first:$first,after:$after)", shape) + "}}}"
        data = client.request(query, {"id": arg("customer_id"), "first": int(arg("limit")), "after": arg("cursor") or None})
        if not data.get("node") or field not in data["node"]:
            raise Failure("Customer not found")
        return page(data["node"][field], shape)
    if op in ("transaction_refunds", "transaction_history", "subscription_transactions", "dispute_evidence"):
        kind, field, shape = {"transaction_refunds": ("transaction", "refunds", PAYMENT), "transaction_history": ("transaction", "statusHistory", HISTORY),
                              "subscription_transactions": ("subscription", "transactionIds", None), "dispute_evidence": ("dispute", "evidence", EVIDENCE)}[op]
        obj = client.node(kind, arg("id"), {"id": None, field: shape})
        rows = obj.get(field) or []
        start, limit = int(arg("offset")), int(arg("limit"))
        end = min(start + limit, len(rows))
        return {"results": [project(item, shape) for item in rows[start:end]], "pagination": {"has_more": end < len(rows), "next_offset": end if end < len(rows) else None}}
    if op in ("evidence_file_info", "upload_dispute_file"):
        upload = file_bytes()
        digest = hashlib.sha256(upload[1]).hexdigest()
        if op == "evidence_file_info":
            return {"result": {"file_name": upload[0], "size": len(upload[1]), "sha256": digest, "mime_type": upload[2]}}
        if digest != arg("expected_file_sha256"):
            raise Failure("Evidence file changed since review")
        return {"result": client.mutate("createDisputeFileEvidence", "CreateDisputeFileEvidenceInput", {"disputeId": arg("dispute_id"), "category": arg("category")}, {"evidence": EVIDENCE, "dispute": DISPUTE}, upload)}
    if op in ("refund_transaction", "capture_transaction", "void_transaction"):
        if op != "void_transaction" and Decimal(arg("amount")) <= 0:
            raise Failure("Amount must be positive")
        current = client.node("transaction", arg("transaction_id"), PAYMENT)
        if current.get("merchantAccountId") != arg("merchant_account_id") or current.get("amount", {}).get("currencyCode") != arg("currency"):
            raise Failure("Transaction merchant account or currency differs from the approved target")
        values = {"transactionId": arg("transaction_id"), "apiRequestKey": arg("operation_id")}
        if op == "refund_transaction":
            values["refund"] = {"amount": arg("amount"), "orderId": arg("order_id")}
            name, input_type, result = "refundTransaction", "RefundTransactionInput", {"refund": SELECT["refund"]}
        elif op == "capture_transaction":
            values["transaction"] = {"amount": arg("amount")}
            name, input_type, result = "captureTransaction", "CaptureTransactionInput", {"transaction": SELECT["transaction"]}
        else:
            name, input_type, result = "voidTransaction", "VoidTransactionInput", {"transaction": SELECT["transaction"]}
        return {"result": client.mutate(name, input_type, values, result)}
    if op in ("retry_subscription", "cancel_subscription", "set_subscription_price", "set_subscription_payment_method"):
        current = client.node("subscription", arg("subscription_id"), SUBSCRIPTION)
        if current.get("timeline", {}).get("updatedAt") != arg("expected_updated_at"):
            raise Failure("Subscription changed since review; investigate before correcting it")
        if op in ("retry_subscription", "set_subscription_price"):
            plan = client.node("plan", current["planId"], {**IDENTITY, "price": MONEY})
            if current.get("merchantAccountId") != arg("merchant_account_id") or plan.get("price", {}).get("currencyCode") != arg("currency"):
                raise Failure("Subscription merchant account or currency differs from the approved target")
        if op == "retry_subscription":
            if current.get("status") != "PAST_DUE" or Decimal(current["balance"]) != Decimal(arg("amount")) or Decimal(arg("amount")) <= 0:
                raise Failure("Retry must collect exactly the current positive past-due balance")
            values = {"subscriptionId": arg("subscription_id"), "amount": arg("amount"), "submitForSettlement": True}
            result = client.mutate("chargeRecurringBillingSubscription", "ChargeRecurringBillingSubscriptionInput", values, {"transaction": SELECT["transaction"]})
        elif op == "cancel_subscription":
            result = client.mutate("cancelRecurringBillingSubscription", "CancelRecurringBillingSubscriptionInput", {"subscriptionId": arg("subscription_id")}, {"subscription": SUBSCRIPTION})
        else:
            values = {"subscriptionId": arg("subscription_id"), "overrides": {"prorateCharges": False, "revertSubscriptionOnProrationFailure": True}}
            if op == "set_subscription_price":
                if Decimal(current["price"]) != Decimal(arg("expected_price")):
                    raise Failure("Subscription price changed since review")
                values["price"] = arg("price")
            else:
                if current.get("paymentMethodId") != arg("expected_payment_method_id"):
                    raise Failure("Subscription payment method changed since review")
                old = client.node("payment_method", current["paymentMethodId"], {**IDENTITY, "customer": IDENTITY})
                new = client.node("payment_method", arg("payment_method_id"), {**IDENTITY, "customer": IDENTITY})
                if not old.get("customer", {}).get("id") or old["customer"]["id"] != (new.get("customer") or {}).get("id"):
                    raise Failure("Replacement payment method must belong to the same customer")
                values["paymentMethodId"] = arg("payment_method_id")
            result = client.mutate("updateRecurringBillingSubscription", "UpdateRecurringBillingSubscriptionInput", values, {"subscription": SUBSCRIPTION})
        return {"result": result}
    if op in ("stage_dispute_text", "remove_dispute_evidence", "submit_dispute_evidence", "accept_dispute"):
        values = {"disputeId": arg("dispute_id")}
        if op == "stage_dispute_text":
            values.update({"category": arg("category"), "content": arg("content")})
            return {"result": client.mutate("createDisputeTextEvidence", "CreateDisputeTextEvidenceInput", values, {"evidence": EVIDENCE})}
        if op == "remove_dispute_evidence":
            values["evidenceId"] = arg("evidence_id")
            client.mutate("deleteDisputeEvidence", "DeleteDisputeEvidenceInput", values, {"clientMutationId": None})
            current = client.node("dispute", arg("dispute_id"))
            if any(row.get("id") == arg("evidence_id") for row in current.get("evidence", [])):
                raise Failure("Evidence still present after deletion")
            return {"result": project(current, SELECT["dispute"])}
        if op == "submit_dispute_evidence":
            current = client.node("dispute", arg("dispute_id"))
            rows = current.get("evidence") or []
            if not rows or evidence_digest(rows) != arg("expected_evidence_sha256"):
                raise Failure("Evidence inventory changed since review or is empty")
            return {"result": client.mutate("finalizeDispute", "FinalizeDisputeInput", values, {"dispute": DISPUTE})}
        return {"result": client.mutate("acceptDispute", "AcceptDisputeInput", values, {"dispute": DISPUTE})}
    raise Failure("Unknown Braintree operation")


def main():
    client = Client()
    result = run(client, sys.argv[1])
    result["context"] = {"environment": client.mode, "api_version": "2026-09-08", "request_id": client.request_id}
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
    except (ValueError, TypeError, KeyError, IndexError, OSError, RecursionError, ArithmeticError):
        print("Invalid input or provider response; reconcile any attempted write before retrying", file=sys.stderr)
        sys.exit(1)
