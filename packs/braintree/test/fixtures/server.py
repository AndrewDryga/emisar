"""Stateful billing model validated against Braintree's pinned official SDL."""
import base64
import copy
import json
from decimal import Decimal
from email.parser import BytesParser
from email.policy import default
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

from graphql import GraphQLError, build_schema, graphql_sync

SCHEMA = build_schema(Path('/fixture/schema.graphql').read_text())
STATE = json.loads(Path(__file__).with_name('seed.json').read_text())
WRITES = 0
REQUESTS = 0
REPLAYS = {}
MODE = ''
UPLOAD = None
KINDS = {'transactions': 'transaction', 'refunds': 'refund', 'customers': 'customer', 'disputes': 'dispute', 'recurringBillingSubscriptions': 'subscription'}


def connection(rows, first, after):
    start = int(after.split('_')[-1]) if after else 0
    end = min(start + first, len(rows))
    return {'edges': [{'node': row} for row in rows[start:end]], 'pageInfo': {'hasNextPage': end < len(rows), 'endCursor': 'page_' + str(end)}}


def resolve(source, info, **args):
    global WRITES
    field = info.field_name
    if info.parent_type.name == 'Query':
        if MODE == 'graphql_error':
            raise GraphQLError('packtest-canary-braintree-custom-477a', extensions={'errorClass': 'AUTHORIZATION'})
        if field == 'viewer':
            return {'merchant': STATE['merchant']}
        if field == 'idsFromLegacyIds':
            item = args['input']['ids'][0]
            if item['legacyId'] != 'tx123' or item['type'] != 'TRANSACTION':
                raise GraphQLError('Unknown fixture legacy identifier')
            return ['transaction_fixture']
        if field == 'node':
            identifier = args['id']
            if identifier == 'method_new':
                node = copy.deepcopy(STATE['payment_method'])
                node['id'] = identifier
                if MODE == 'cross_customer':
                    node['customer']['id'] = 'customer_other'
                return node
            return next((value for value in STATE.values() if value.get('id') == identifier), None)
        if field in KINDS:
            kind = KINDS[field]
            rows = [copy.deepcopy(STATE[kind]) for _ in range(12)]
            if MODE == 'empty' or (field == 'customers' and args['input'].get('email', {}).get('is') not in (None, STATE['customer']['email'])):
                rows = []
            for i, row in enumerate(rows):
                if i:
                    row['id'] += '_' + str(i)
                if MODE == 'maximum':
                    for key in ('email', 'firstName', 'lastName', 'company', 'orderId'):
                        row[key] = '\\"' * 10000
            return connection(rows, args['first'], args.get('after'))
    if info.parent_type.name == 'Merchant' and field == 'merchantAccounts':
        return connection([STATE['merchant_account']], args['first'], args.get('after'))
    if info.parent_type.name == 'Customer' and field in ('paymentMethods', 'transactions'):
        kind = 'payment_method' if field == 'paymentMethods' else 'transaction'
        return connection([STATE[kind]], args['first'], args.get('after'))
    if info.parent_type.name == 'Mutation':
        values = args['input']
        key = values.get('apiRequestKey')
        if key and key in REPLAYS:
            old, result = REPLAYS[key]
            if old != [field, values]:
                raise GraphQLError('Request key reused with changed parameters', extensions={'errorClass': 'VALIDATION'})
            return result
        if field in ('refundTransaction', 'captureTransaction', 'voidTransaction'):
            if values['transactionId'] != STATE['transaction']['id'] or not key:
                raise GraphQLError('Wrong transaction or missing request key')
            tx = STATE['transaction']
            if MODE == 'declined':
                tx['status'] = 'PROCESSOR_DECLINED'
                WRITES += 1
                return {'transaction': tx, 'refund': {**STATE['refund'], 'status': 'PROCESSOR_DECLINED'}}
            if field == 'refundTransaction':
                if tx['status'] not in ('SETTLED', 'SETTLING'):
                    raise GraphQLError('Transaction is not refundable')
                refund = STATE['refund']
                refund.update(amount={'value': values['refund']['amount'], 'currencyCode': 'USD'}, orderId=values['refund']['orderId'], status='SUBMITTED_FOR_SETTLEMENT')
                tx['refundedAmount'] = values['refund']['amount']
                result = {'refund': refund}
            elif field == 'captureTransaction':
                if tx['status'] != 'AUTHORIZED':
                    raise GraphQLError('Transaction is not authorized')
                tx.update(status='SUBMITTED_FOR_SETTLEMENT', amount={'value': values['transaction']['amount'], 'currencyCode': 'USD'})
                result = {'transaction': tx}
            else:
                if tx['status'] not in ('AUTHORIZED', 'SUBMITTED_FOR_SETTLEMENT'):
                    raise GraphQLError('Transaction is not voidable')
                tx['status'] = 'VOIDED'
                result = {'transaction': tx}
        elif field in ('chargeRecurringBillingSubscription', 'cancelRecurringBillingSubscription', 'updateRecurringBillingSubscription'):
            sub = STATE['subscription']
            if values['subscriptionId'] != sub['id']:
                raise GraphQLError('Wrong subscription')
            if field == 'chargeRecurringBillingSubscription':
                if sub['status'] != 'PAST_DUE' or Decimal(values['amount']) != Decimal(sub['balance']) or not values['submitForSettlement']:
                    raise GraphQLError('Incorrect past-due retry')
                sub.update(balance='0.00', status='ACTIVE')
                STATE['transaction']['status'] = 'SUBMITTED_FOR_SETTLEMENT'
                result = {'transaction': STATE['transaction']}
            elif field == 'cancelRecurringBillingSubscription':
                sub['status'] = 'CANCELED'
                result = {'subscription': sub}
            else:
                if values.get('overrides', {}).get('prorateCharges') is not False:
                    raise GraphQLError('Proration must be explicit')
                if 'price' in values:
                    if sub['status'] != 'ACTIVE':
                        raise GraphQLError('Price update requires active subscription')
                    sub['price'] = values['price']
                if 'paymentMethodId' in values:
                    sub['paymentMethodId'] = values['paymentMethodId']
                result = {'subscription': sub}
            sub['timeline']['updatedAt'] = '2026-09-08T00:00:00Z'
        elif field in ('createDisputeTextEvidence', 'createDisputeFileEvidence', 'deleteDisputeEvidence', 'finalizeDispute', 'acceptDispute'):
            dispute = STATE['dispute']
            if values['disputeId'] != dispute['id'] or dispute['status'] != 'OPEN':
                raise GraphQLError('Dispute must be open')
            if field in ('createDisputeTextEvidence', 'createDisputeFileEvidence'):
                evidence = {'__typename': 'DisputeTextEvidence' if field == 'createDisputeTextEvidence' else 'DisputeFileEvidence', 'id': 'evidence_added', 'legacyId': 'ev_added', 'createdAt': '2026-09-08T00:00:00Z', 'sentToProcessorAt': None, 'category': values['category']}
                if field == 'createDisputeTextEvidence':
                    evidence['content'] = values['content']
                elif not UPLOAD or not UPLOAD.startswith(b'%PDF-'):
                    raise GraphQLError('Missing multipart evidence')
                dispute['evidence'].append(evidence)
                result = {'evidence': evidence, 'dispute': dispute}
            elif field == 'deleteDisputeEvidence':
                dispute['evidence'] = [row for row in dispute['evidence'] if row['id'] != values['evidenceId']]
                result = {'clientMutationId': None}
            else:
                dispute['status'] = 'DISPUTED' if field == 'finalizeDispute' else 'ACCEPTED'
                result = {'dispute': dispute}
        else:
            raise GraphQLError('Unsupported fixture mutation')
        WRITES += 1
        if key:
            REPLAYS[key] = ([field, copy.deepcopy(values)], copy.deepcopy(result))
        if MODE == 'ambiguous':
            raise GraphQLError('Processor response lost after apply', extensions={'errorClass': 'UNKNOWN'})
        return result
    return source.get(field) if isinstance(source, dict) else None


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def send(self, obj, status=200):
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps(obj).encode())

    def do_GET(self):
        if self.path == '/health':
            return self.send({'ok': True})
        if self.path == '/probe':
            return self.send({'state': STATE, 'writes': WRITES, 'requests': REQUESTS})
        self.send({}, 404)

    def do_POST(self):
        global MODE, REQUESTS, UPLOAD
        if self.path.startswith('/arrange/'):
            MODE = self.path.rsplit('/', 1)[-1]
            if MODE == 'authorized':
                STATE['transaction']['status'] = 'AUTHORIZED'
            if MODE == 'active':
                STATE['subscription']['status'] = 'ACTIVE'
            return self.send({'arranged': MODE})
        REQUESTS += 1
        authorization = 'Basic ' + base64.b64encode(b'packtest-canary-braintree-public-749a:packtest-canary-braintree-private-28ac').decode()
        if self.headers.get('Authorization') != authorization or self.headers.get('Braintree-Version') != '2026-09-08':
            return self.send({'errors': [{'message': 'Unauthenticated'}]}, 401)
        if MODE == 'http_error':
            return self.send({'errors': [{'message': 'Unavailable'}]}, 503)
        if MODE == 'redirect':
            self.send_response(302)
            self.send_header('Location', 'http://127.0.0.1:1/leak')
            self.end_headers()
            return
        raw = self.rfile.read(int(self.headers['Content-Length']))
        if self.headers.get('Content-Type', '').startswith('multipart/form-data'):
            message = BytesParser(policy=default).parsebytes(('Content-Type: ' + self.headers['Content-Type'] + '\r\n\r\n').encode() + raw)
            parts = {part.get_param('name', header='content-disposition'): part for part in message.iter_parts()}
            if parts['operations'].get_content_type() != 'application/json' or json.loads(parts['map'].get_payload(decode=True)) != {'file_to_upload': 'variables.file'}:
                return self.send({'errors': [{'message': 'Incorrect upload map or content type'}]}, 400)
            payload = json.loads(parts['operations'].get_payload(decode=True))
            UPLOAD = parts['file_to_upload'].get_payload(decode=True)
        else:
            payload = json.loads(raw)
        result = graphql_sync(SCHEMA, payload['query'], variable_values=payload.get('variables'), field_resolver=resolve)
        response = {'data': result.data, 'extensions': {'requestId': 'request_fixture'}}
        if result.errors:
            response['errors'] = [error.formatted for error in result.errors]
            print(json.dumps(response['errors']), flush=True)
        self.send(response)


HTTPServer(('0.0.0.0', 8080), Handler).serve_forever()
