# Professor dashboard: fix "Card could not be verified"

For the professor dashboard (ci-track) team.

> **The fix that was chosen is in `README.md`:** the website's card scanner
> now uses the CompTech app's own `nfc-attendance` function and reads cards
> with the same rules, so both scanners work the same way. This file explains
> what went wrong; its "fix" sections describe an earlier approach (patching
> `faculty-nfc-attendance`) and are kept for reference only.

## What goes wrong

Scanning a student card on the dashboard website (Chrome on Android) always
fails with **Card could not be verified**. The function log shows:

```
nfc_attendance_api scan failed: { cardUid: "0413e301461013", message: "ACTIVE_CARD_REQUIRED" }
```

1. **Wrong token hash.** Cards written by the student app hold
   `COMPTECH:NFC:CARD:V1:<64 hex characters>`. `student_nfc_cards.card_token_hash`
   is the SHA-256 of **only the 64 hex characters**. `faculty-nfc-attendance`
   hashes the whole text, prefix included, so no card ever matches.
2. **No wait for the student's phone.** `nfc_attendance_api` `scan` doesn't
   record attendance by itself. It returns a `challenge_id`. The student's
   phone confirms it (NFC Attendance → Use Card → Enable Attendance
   Readiness), and only then is attendance saved. The student app's scanner
   checks `scan_status` until that happens. The website has no such step, so
   after fix 1 it would say "Attendance recorded successfully" before
   anything is saved.
3. **The real error is hidden.** The website shows scan errors in
   `nfcSessionMessage`, but the class-timer sync overwrites that with "This
   live class session and timer are synchronized across all faculty
   devices."

## First, check `nfc_attendance_api` (read-only)

Fix 2 uses the `scan_status` action of `nfc_attendance_api`, which the student
app's scanner already relies on. Run this in the SQL Editor; the result should
include `scan` and `scan_status`:

```sql
select distinct m[1] as action
from pg_proc p, regexp_matches(p.prosrc, '''(scan[a-z_]*)''', 'g') m
where p.proname = 'nfc_attendance_api';
```

## 1. Edge Function `faculty-nfc-attendance`

**a. Accept a `scan_status` action.**

```ts
type FacultyNfcAction =
  | "scanner_context"
  | "session_open"
  | "session_close"
  | "scan"
  | "scan_status"

type RequestPayload = {
  // ...existing fields...
  challengeId?: string
  challenge_id?: string
}

const allowedActions: FacultyNfcAction[] = [
  "scanner_context",
  "session_open",
  "session_close",
  "scan",
  "scan_status",
]
```

**b. In `scan`, hash only the token.** Replace the `cardToken` lines:

```ts
const rawToken = String(
  payload.cardToken ??
    payload.card_token ??
    "",
).trim()

// Cards written by the student app hold "COMPTECH:NFC:CARD:V1:<64 hex>".
// card_token_hash is the SHA-256 of the 64 hex characters only.
const appCard = rawToken.match(/^COMPTECH:NFC:CARD:V1:([0-9a-f]{64})$/i)
const cardToken = appCard ? appCard[1].toLowerCase() : rawToken
```

The rest of `scan` stays as it is.

**c. Add `scan_status`**, before the final `ACTION_NOT_ALLOWED` return:

```ts
/*
 * SCAN STATUS
 *
 * After a scan, the student's phone confirms the challenge. Returns
 * { attendance } once attendance is saved.
 */
if (action === "scan_status") {
  const challengeId = String(
    payload.challengeId ??
      payload.challenge_id ??
      "",
  ).trim()

  if (!isUuid(challengeId)) {
    return json(
      {
        success: false,
        error: "INVALID_CHALLENGE_ID",
        message: "The scan challenge ID is invalid.",
      },
      400,
    )
  }

  const { data, error } = await adminClient.rpc(
    "nfc_attendance_api",
    {
      p_actor: actorId,
      p_action: "scan_status",
      p_body: { challenge_id: challengeId },
    },
  )

  if (error) {
    console.error("nfc_attendance_api scan_status failed:", {
      actorId,
      challengeId,
      message: error.message,
      code: error.code,
    })

    return json(
      {
        success: false,
        error: error.message,
        message: error.message,
      },
      400,
    )
  }

  return json({ success: true, data })
}
```

Deploy the function after editing.

## 2. Dashboard `App.tsx`

> **Superseded by `App.tsx` / `App.tsx.patch` (see `README.md`).** Kept for
> reference.

**a. Keep scan errors visible.** Add next to the other NFC state:

```ts
const [nfcScanError, setNfcScanError] = useState("")

const nfcErrorText = (code: string) =>
  ({
    ACTIVE_CARD_REQUIRED:
      "This card isn't an active registered card. The student can re-register it in the student app.",
    CARD_UID_MISMATCH:
      "The card's token doesn't belong to this card. The student should re-register it.",
    NOT_ENROLLED: "This student isn't enrolled in this class.",
    SESSION_NOT_ACTIVE: "This class session has ended or isn't open for NFC.",
    NFC_TEST_SESSION_REQUIRED: "This class session isn't set up for NFC. End it and start it again.",
    LATE_REQUIRES_FACULTY_CONFIRMATION:
      "The 30-minute check-in window has passed. Mark this student manually.",
    REGISTERED_PHONE_REQUIRED: "This student has no registered phone in the student app.",
  } as Record<string, string>)[code] ?? code
```

In the scanner card, show the error while there is one:

```tsx
<small>
  {nfcScannerStatus === "error" && nfcScanError ? nfcScanError : nfcSessionMessage}
</small>
```

**b. Wait for the student's phone after a scan.** In the `reading` handler,
replace the block from `const data = await invokeFacultyNfc({` through the
`setNfcSessionMessage(data?.already_recorded ? ... )` call with:

```ts
setNfcScanError("")

const scanned = await invokeFacultyNfc({
  action: "scan",
  sessionId: activeSessionId,
  cardUid,
  cardToken,
})

// "attendance" right away means this student was already recorded.
const alreadyRecorded = Boolean(scanned?.attendance)
let data: any = scanned

if (!alreadyRecorded) {
  const challengeId = String(scanned?.challenge_id ?? "")
  if (!challengeId) {
    throw new Error("The scan didn't return a challenge. Scan the card again.")
  }

  setNfcSessionMessage(
    "Card read. Waiting for the student's phone. They need NFC Attendance → Use Card open with readiness on.",
  )

  data = null
  const deadline = Date.now() + 65_000
  while (Date.now() < deadline) {
    await new Promise((resolve) => window.setTimeout(resolve, 2000))
    const status = await invokeFacultyNfc({ action: "scan_status", challengeId })
    if (status?.attendance) {
      data = status
      break
    }
  }

  if (!data) {
    throw new Error(
      "The student's phone didn't confirm in time. Ask them to open NFC Attendance → Use Card, select this class, tap Enable Attendance Readiness, then scan again.",
    )
  }
}

if (scannerMode === "performance") {
  // ...existing performance block, using data.attendance...
}
nfcReaderRef.current = null
setNfcScannerStatus("success")
setNfcSessionMessage(
  alreadyRecorded
    ? "This student was already recorded for the active class session."
    : "Attendance recorded successfully.",
)
```

In the matching `catch`, use the readable message and keep it out of the
synced message:

```ts
nfcReaderRef.current = null
setNfcScannerStatus("error")
setNfcScanError(
  error instanceof Error
    ? nfcErrorText(error.message)
    : "The scanned card could not be verified.",
)
```

## How to test

1. On the dashboard (Chrome on Android), start the class and tap **Scan
   student card**.
2. On the student's phone, open **NFC Attendance → Use Card**, select the
   class and tap **Enable Attendance Readiness**.
3. Hold the card to the professor's phone. The dashboard should say it's
   waiting for the student's phone, then **Attendance recorded**, and the
   student's screen shows the check-in.
4. Scan the same card again: **already recorded**.
5. Scan with the student's readiness off: after about a minute, the
   dashboard explains that the student's phone didn't confirm.
