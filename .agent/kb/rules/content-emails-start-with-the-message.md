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

Put account context into the opening sentence of an identity email. Do not add a
one-row `Requested from` facts table when `Sign in to Northstar Production` says
the same thing more naturally. Put request metadata after the expiry and safety
copy so it remains available without interrupting the task.

Use paragraph breaks for a real change of job, not after every sentence. Keep a
short instruction with the constraints that explain how to complete it, then
give recovery or `If you didn't request this` guidance its own paragraph. Do not
turn one thought into a stack of one-line fragments, and do not merge the task,
expiry, security boundary, and recovery path into one wall of text.

Text links use the email palette's brand green. A new sign-in email address is
bold wherever the recipient must verify which address they are changing to;
the label around it stays in the normal body tier.

A terminal approval email names the person who denied the request when that
identity resolves inside the request's account. An approved request links to both
the approval record and the resulting action run or runbook execution; the run is
a quiet secondary action, not a second primary button.

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

```text
Hi Avery,

Use this code to add an authenticator to your emisar sign-in to Northstar Production.

    627194

This code works once and expires in 15 minutes.

If you didn't start this setup, ignore the email. Your authenticator settings will not change.

REQUEST DETAILS

  Time:   25 Aug 2026 at 18:19 UTC
  From:   203.0.113.42
  Device: Chrome on macOS
```

In HTML, `Northstar Production` is the account link. There is no separate account
facts table.

```text
Enter the code in the browser where you asked to sign in. It works once, only in that browser, and expires in 15 minutes.

If you didn't ask to sign in, ignore this email.
```

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
