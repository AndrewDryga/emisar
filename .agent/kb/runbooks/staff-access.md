---
name: staff-access
sources: [portal/apps/emisar/lib/emisar/release.ex, portal/apps/emisar/lib/emisar/admin.ex, portal/apps/emisar_web/lib/emisar_web/staff_auth.ex]
updated: 2026-10-03
---

# Staff access

The staff console (`/admin`) and LiveDashboard (`/ops/live`) accept only a staff
login. A staff login is not a workspace Member. It has its own table, its own
12-hour sessions in its own cookie, and its own sign-in at `/admin/sign_in`.
Every sign-in needs the code emailed to the staff address and the current code
from the authenticator app. There are no recovery codes, no SSO, no invitations
and no setting or environment variable that grants staff access.

Staff logins are created, reset and removed only from a shell on a production
node. Nothing in the web app, MCP, or the private admin pack can do it.

## Get a shell on the node

```
./run ops portal remsh
```

## Create a staff login

```
Emisar.Release.create_staff("you@emisar.dev")
```

It prints a QR code and the authenticator key once. Scan the code or type the
key into the authenticator app, then sign in at `/admin/sign_in`. Nobody can
read the key again; a lost key needs a reset.

## Lost device or locked login

Five wrong authenticator codes in a row, each after a correct emailed code, lock
the login. Only someone who can read the staff inbox gets that far, so treat an
unexpected lock as a sign the inbox may be compromised.

```
Emisar.Release.reset_staff("you@emisar.dev")
```

The reset prints a new key, unlocks the login, and ends every session it holds.

## Remove a staff login

```
Emisar.Release.remove_staff("former@emisar.dev")
Emisar.Release.list_staff()
```

Removing a login ends its sessions at once and disconnects its open consoles.
