# SAP × SailPoint Auto Access Request — 5-min Demo

**Persona on screen:** Maria Gonzalez — Accounts Payable clerk, company code 1000.
**Persona behind the curtain:** "Atlas" — an autonomous AI procurement agent with valid SailPoint API credentials that goes off the rails.

**Pre-flight (before clicking record):**
- SAP GUI logged in as MARIA. Transaction FB60 ready.
- Browser tabs:
  1. SailPoint Request Center (logged in as Maria's manager)
  2. SailPoint Search → filtered to identity `Atlas` (or audit events view)
- Terminal split: top = `tail -f` of bot log, bottom = ABAP output console / SAP GUI.
- `.env` loaded. `./get_token.sh` already validated returns a token.
- A second terminal pre-staged with `source .env && ./rogue_bot.sh` — do not press enter yet.

---

## Scene 1 — The wall (0:00–0:45)

**Show:** SAP GUI, transaction FB60 (Enter Vendor Invoice).

**Say:**
> "Maria works in AP. She just got a vendor invoice for company code 1000 and needs to post it. Watch what happens."

**Do:** Enter FB60, fill minimal fields, hit Post.

**Show:** SAP error — "No authorization for company code 1000" (auth object F_BKPF_BUK).

**Say:**
> "Today this is a dead end. Email the helpdesk, file a ticket, wait two days, lose the early-pay discount. We can do better."

---

## Scene 2 — The Z program closes the loop (0:45–2:15)

**Show:** SE38 → run `ZAUTH_TO_SAILPOINT`.

**Say:**
> "We've wrapped the auth check in a small Z program. Same AUTHORITY-CHECK, but on failure it doesn't just stop — it talks to SailPoint."

**Do:** Run the report. It prints:
```
AUTHORITY-CHECK failed for F_BKPF_BUK (BUKRS=1000, ACTVT=01).
Initiating SailPoint access request...
SailPoint HTTP 202
SailPoint request accepted. ID: 2c91808a...
```

**Say while it runs:**
> "Two API calls. First, OAuth client-credentials — the SAP system has its own SailPoint identity. Second, POST to `/v3/access-requests`. Notice the `clientMetadata` — we tag every request with the source system, the SAP transaction code, and the auth object that failed. That's a forensic breadcrumb governance teams love."

**Switch to:** SailPoint Request Center (manager's view).

**Show:** New pending request for Maria, with the SAP context visible in the comments.

**Say:**
> "Manager sees it instantly, with the business context — not 'Maria wants role X' but 'Maria failed auth posting an invoice in BUKRS 1000.' That changes the approval conversation."

**Do:** Approve. Show provisioning kick off (or mock the back-channel — SailPoint → SAP role assignment).

---

## Scene 3 — Atlas goes rogue (2:15–4:00)

**Say:**
> "Now the part that should make every security architect lean in. Same API, same credentials pattern — but this time the caller isn't a Z program. It's an autonomous AI agent named Atlas. Atlas has a bug. Or a prompt injection. Or both. Watch."

**Do:** Switch to staged terminal. Press enter on `./rogue_bot.sh`.

**Show:** Status codes streaming:
```
req=001  status=202
req=002  status=202
req=003  status=202
...
req=047  status=429
req=048  status=429
req=049  status=429
...
```

**Say while it runs:**
> "Three things are happening here. One: SailPoint's rate limiter is doing exactly what it's supposed to — protecting itself and the downstream connectors from a runaway client. Two: every one of those 429s comes back with a `Retry-After` header, so a well-behaved client knows how to back off. Three —"

**Do:** Show the tally at the end:
```
237  202
 63  429
```

**Switch to:** SailPoint Search / audit events filtered to Atlas's identity.

**Say:**
> "— SailPoint sees the burst. Volume anomaly on a service identity. In a production tenant we'd wire an Event Trigger on `Access Request Submitted` into a workflow that suspends the account, pages the SOC, and revokes the API token. This is the control plane doing its job."

---

## Scene 4 — The point (4:00–4:45)

**Say:**
> "What you just saw isn't a SailPoint feature demo. It's three things stitched together:
>
> 1. **SAP becomes self-serve.** The auth wall turns into a request, with full business context attached.
> 2. **Every identity action is observable.** Human or machine, governed the same way.
> 3. **The platform defends itself.** Rate limits and anomaly signals turn a runaway agent into a containable incident, not a breach.
>
> That last one matters more every quarter. The number of non-human identities in your tenant is going up and to the right. SailPoint is the only place that scales with it."

---

## Scene 5 — Wrap (4:45–5:00)

**Say:**
> "Happy to dig into the API surface, the workflow side, or how we'd harden this for production. Where do you want to go?"

---

## Backup plan if the live API fails

- Pre-record Scene 2 and Scene 3 as 30-fps screen captures.
- Have a `mock_server.py` (Flask, two endpoints, returns 202 then 429 after N) and flip `SAILPOINT_TENANT_API` to `http://localhost:8080`. Don't mention the swap.

## Things to know if asked

- **Rate limits:** SailPoint ISC publishes per-endpoint limits. Standard reads ~100 rps, writes lower, bulk endpoints lowest. 429 includes `Retry-After`.
- **Anomaly detection:** Identity Outliers + AI-Driven Identity Security flag unusual access patterns. Event Triggers fire on lifecycle events and can route to external workflows (Slack, ServiceNow, custom).
- **Auth:** OAuth2 client_credentials for service-to-service; PAT for user; OIDC for UI.
- **Why `clientMetadata`:** Free-form JSON map on the request, surfaces in audit and approval UI. Real field, not invented for the demo.

## After the demo

- Rotate `SAILPOINT_CLIENT_SECRET`. The one used today has been seen in chat logs.
- Delete `bot_run.log` and `token.txt`.
