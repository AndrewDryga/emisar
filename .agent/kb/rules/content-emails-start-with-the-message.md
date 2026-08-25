# Transactional email starts with the message

## Rule

Keep the subject in the inbox. Do not repeat it as a large display title before
the greeting. After `Hi`, start with the sentence the recipient needs:

- what they need to do;
- what changed;
- or what the account did during the period.

Write that sentence in simple English. For an outcome, bold the load-bearing
status word in HTML and use the same semantic color as the console: green for
approved, amber for waiting, expired, or cancelled, and rose for denied or
failed. The plain-text alternative carries the same sentence without relying on
color.

Every account-scoped email names the account near the start, renders that name
as a link, and links the action back to that account. Identity email is
cross-account: when the request started from an existing account, link and name
it as the origin; when it did not, do not invent one. A new-account sign-up may
name the account being created, but it cannot link an account that does not exist
yet.

Do not add chrome that explains itself (`This message was sent by emisar`) or a
disclaimer that repeats the noun in the sentence. Name the object precisely
instead: `The approval request was approved` does not claim that the action ran.
Keep a boundary sentence only when it changes what the recipient should decide
or do.

## Why

The email client already shows the subject and sender. Repeating both spends the
most prominent part of the message on information the reader just saw.

Defensive copy makes a direct product sound unsure. Precise nouns carry the
boundary more clearly: an approval result is about the approval request, while
the linked run or approval page carries the current execution state.

Account context prevents a forwarded or delayed email from becoming ambiguous,
especially for operators who belong to more than one account.

## Good

```text
Hi Riley,

Your approval request was cancelled with 1 of 2 approvals.

  Account:    Northstar Production
  Request:    postgres.vacuum_table
  Approvals:  1 of 2
```

In HTML, only `cancelled` is bold and amber. The subject remains `Approval
cancelled · postgres.vacuum_table`; it is not rendered again above `Hi`.

## Bad

```text
Approval cancelled · postgres.vacuum_table

Hi Riley,

The gate closed at 1 of 2.
```

```text
This is the approval outcome, not proof that the action ran. Open emisar for
current execution status and the full decision record.
```

```text
This message was sent by emisar.
```

## Enforcement

Mailer tests render representative identity, invitation, approval, and report
messages. They assert that the visible HTML starts with the greeting, status
emphasis uses the semantic palette, account context is present when available,
and the rejected default footer and approval disclaimers do not return.
