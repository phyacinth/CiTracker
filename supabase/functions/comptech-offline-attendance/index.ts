// Offline attendance uploads (see migrations/20261103030000_offline_attendance.sql).
//
// Phones that had no internet send what they saved here once they reconnect.
// This function checks the student's registered-phone signature, which
// Postgres can't verify, then hands each item to a database function that
// applies the attendance rules. Every value is read from the signed message,
// never from fields the uploader could change.
//
// POST { action: "qr" | "location" | "phone_taps", items: [...] }
//   qr          (student)    { message, signature, token, place_name? }
//   location    (student)    { message, signature, place_name? }
//   phone_taps  (professor)  { message, signature, session_started_at?,
//                              latitude?, longitude?, accuracy_m?, is_mocked? }
// Returns { results: [{ upload_id, status, code? }] }. status is "recorded",
// "already_recorded", "rejected" (final), "pending" (try again later) or
// "error" (temporary; try again later).

import { createClient } from "jsr:@supabase/supabase-js@2";

const admin = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { persistSession: false } },
);

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const MAX_ITEMS = 50;
// The offline scanner sets a tap's expiry 45 seconds after the tap; the
// student's phone only signs expiries within 60 seconds of its own clock.
const TAP_EXPIRY_OFFSET_S = 45;

type Item = Record<string, unknown>;
type Result = { upload_id: string | null; status: string; code?: string };
type Fields = Record<string, string>;

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });
}

class Reject extends Error {
  constructor(readonly code: string) {
    super(code);
  }
}

function hex(bytes: ArrayBuffer): string {
  return [...new Uint8Array(bytes)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function sha256Hex(data: Uint8Array | string): Promise<string> {
  const bytes = typeof data === "string" ? new TextEncoder().encode(data) : data;
  return hex(await crypto.subtle.digest("SHA-256", bytes));
}

function base64Bytes(value: string): Uint8Array {
  return Uint8Array.from(atob(value), (c) => c.charCodeAt(0));
}

// public_key_spki may come back as base64 text or as a bytea hex string.
function spkiBytes(value: unknown): Uint8Array {
  if (typeof value !== "string" || value.length === 0) throw new Reject("CREDENTIAL_INVALID");
  if (value.startsWith("\\x")) {
    const text = value.slice(2);
    return Uint8Array.from(text.match(/../g) ?? [], (h) => parseInt(h, 16));
  }
  return base64Bytes(value);
}

// Android signs ECDSA as DER; WebCrypto expects raw r || s (32 bytes each).
function derToRaw(der: Uint8Array): Uint8Array {
  let i = 0;
  if (der[i++] !== 0x30) throw new Reject("SIGNATURE_INVALID");
  let length = der[i++];
  if (length & 0x80) {
    const count = length & 0x7f;
    length = 0;
    for (let k = 0; k < count; k++) length = (length << 8) | der[i++];
  }
  const readInteger = () => {
    if (der[i++] !== 0x02) throw new Reject("SIGNATURE_INVALID");
    const size = der[i++];
    let value = der.slice(i, i + size);
    i += size;
    while (value.length > 32 && value[0] === 0) value = value.slice(1);
    if (value.length > 32) throw new Reject("SIGNATURE_INVALID");
    const out = new Uint8Array(32);
    out.set(value, 32 - value.length);
    return out;
  };
  const raw = new Uint8Array(64);
  raw.set(readInteger(), 0);
  raw.set(readInteger(), 32);
  return raw;
}

// Checks the signature with the student's registered phone key, as it was at
// `at`: active by then and not revoked before it.
async function verifyStudentSignature(
  studentId: string,
  fingerprint: string,
  message: string,
  signature: unknown,
  at: Date,
): Promise<void> {
  if (typeof signature !== "string" || signature.length === 0 || signature.length > 200) {
    throw new Reject("SIGNATURE_INVALID");
  }
  const { data, error } = await admin
    .from("student_nfc_phone_credentials")
    .select("public_key_spki, key_fingerprint, activated_at, revoked_at")
    .eq("student_id", studentId)
    .eq("key_fingerprint", fingerprint);
  if (error) throw error;
  const leeway = 60_000;
  const credential = (data ?? []).find((row) =>
    row.activated_at != null &&
    new Date(row.activated_at).getTime() <= at.getTime() + leeway &&
    (row.revoked_at == null || new Date(row.revoked_at).getTime() > at.getTime())
  );
  if (!credential) throw new Reject("REGISTERED_PHONE_REQUIRED");

  const spki = spkiBytes(credential.public_key_spki);
  if ((await sha256Hex(spki)) !== fingerprint) throw new Reject("CREDENTIAL_INVALID");
  const key = await crypto.subtle.importKey(
    "spki", spki, { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"],
  );
  let raw: Uint8Array;
  try {
    raw = derToRaw(base64Bytes(signature));
  } catch {
    throw new Reject("SIGNATURE_INVALID");
  }
  const valid = await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" }, key, raw, new TextEncoder().encode(message),
  );
  if (!valid) throw new Reject("SIGNATURE_INVALID");
}

// "name=value" lines after the purpose line, in a fixed order.
function parse(message: unknown, purpose: string, names: string[]): Fields {
  if (typeof message !== "string" || message.length > 1024) throw new Reject("INVALID_REQUEST");
  const lines = message.split("\n");
  if (lines[0] !== purpose || lines.length !== names.length + 1) throw new Reject("INVALID_REQUEST");
  const fields: Fields = {};
  names.forEach((name, index) => {
    const line = lines[index + 1];
    if (!line.startsWith(`${name}=`)) throw new Reject("INVALID_REQUEST");
    fields[name] = line.slice(name.length + 1);
  });
  return fields;
}

function uuid(value: string): string {
  if (!UUID.test(value)) throw new Reject("INVALID_REQUEST");
  return value;
}

function epoch(value: string): Date {
  if (!/^[0-9]{10}$/.test(value)) throw new Reject("INVALID_REQUEST");
  return new Date(Number(value) * 1000);
}

function location(value: string) {
  if (value === "none") return null;
  const match = value.match(/^(-?[0-9.]+),(-?[0-9.]+),([0-9.]+),([01])$/);
  if (!match) throw new Reject("INVALID_REQUEST");
  return {
    latitude: Number(match[1]),
    longitude: Number(match[2]),
    accuracy_m: Number(match[3]),
    is_mocked: match[4] === "1",
  };
}

function text(value: unknown, max: number): string | null {
  return typeof value === "string" && value.trim() ? value.trim().slice(0, max) : null;
}

function number(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

async function rpc(name: string, params: Record<string, unknown>): Promise<Result> {
  const { data, error } = await admin.rpc(name, params);
  if (error) throw error;
  return data as Result;
}

async function handleQr(userId: string, item: Item): Promise<Result> {
  const f = parse(item.message, "COMPTECH:OFFLINE:QR:V1",
    ["student", "key", "upload", "class", "session", "token", "time", "location"]);
  if (f.student !== userId) throw new Reject("STUDENT_MISMATCH");
  const scannedAt = epoch(f.time);
  await verifyStudentSignature(userId, f.key, item.message as string, item.signature, scannedAt);
  const token = typeof item.token === "string" ? item.token : "";
  if ((await sha256Hex(token)) !== f.token) throw new Reject("QR_INVALID");
  const point = location(f.location);
  return rpc("comptech_offline_qr_checkin", {
    p_student_id: userId,
    p_upload_id: uuid(f.upload),
    p_class_id: uuid(f.class),
    p_session_id: uuid(f.session),
    p_token: token,
    p_scanned_at: scannedAt.toISOString(),
    p_latitude: point?.latitude ?? null,
    p_longitude: point?.longitude ?? null,
    p_accuracy_m: point?.accuracy_m ?? null,
    p_is_mocked: point?.is_mocked ?? false,
    p_place_name: text(item.place_name, 200),
  });
}

async function handleLocation(userId: string, item: Item): Promise<Result> {
  const f = parse(item.message, "COMPTECH:OFFLINE:LOCATION:V1",
    ["student", "key", "upload", "time", "location"]);
  if (f.student !== userId) throw new Reject("STUDENT_MISMATCH");
  const capturedAt = epoch(f.time);
  await verifyStudentSignature(userId, f.key, item.message as string, item.signature, capturedAt);
  const point = location(f.location);
  if (!point) throw new Reject("INVALID_REQUEST");
  return rpc("comptech_offline_attach_location", {
    p_student_id: userId,
    p_upload_id: uuid(f.upload),
    p_captured_at: capturedAt.toISOString(),
    p_latitude: point.latitude,
    p_longitude: point.longitude,
    p_accuracy_m: point.accuracy_m,
    p_is_mocked: point.is_mocked,
    p_place_name: text(item.place_name, 200),
  });
}

// The same message format as an online phone tap, built by the offline
// scanner; the scanner line must be the uploading professor.
async function handlePhoneTap(userId: string, item: Item): Promise<Result> {
  const f = parse(item.message, "COMPTECH:NFC:PHONE_TAP:V1",
    ["student", "key", "challenge", "session", "class", "scanner", "nonce", "expires"]);
  if (f.scanner !== userId) throw new Reject("SCANNER_MISMATCH");
  if (!/^[0-9a-f]{64}$/.test(f.nonce)) throw new Reject("INVALID_REQUEST");
  const tappedAt = new Date(epoch(f.expires).getTime() - TAP_EXPIRY_OFFSET_S * 1000);
  const studentId = uuid(f.student);
  await verifyStudentSignature(studentId, f.key, item.message as string, item.signature, tappedAt);
  const started = typeof item.session_started_at === "string"
    ? new Date(item.session_started_at)
    : null;
  return rpc("comptech_offline_phone_tap", {
    p_professor_id: userId,
    p_upload_id: uuid(f.challenge),
    p_student_id: studentId,
    p_class_id: uuid(f.class),
    p_session_id: uuid(f.session),
    p_session_started_at: started && !isNaN(started.getTime()) ? started.toISOString() : null,
    p_tapped_at: tappedAt.toISOString(),
    p_scanner_latitude: number(item.latitude),
    p_scanner_longitude: number(item.longitude),
    p_scanner_accuracy_m: number(item.accuracy_m),
    p_scanner_is_mocked: item.is_mocked === true,
  });
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (request.method !== "POST") return json({ error: "METHOD_NOT_ALLOWED" }, 405);

  const jwt = request.headers.get("Authorization")?.replace(/^Bearer\s+/i, "");
  if (!jwt) return json({ error: "SIGN_IN_REQUIRED" }, 401);
  const { data: auth, error: authError } = await admin.auth.getUser(jwt);
  if (authError || !auth.user) return json({ error: "SIGN_IN_REQUIRED" }, 401);
  const userId = auth.user.id;

  let body: { action?: unknown; items?: unknown };
  try {
    body = await request.json();
  } catch {
    return json({ error: "INVALID_REQUEST" }, 400);
  }
  const handler = body.action === "qr"
    ? handleQr
    : body.action === "location"
    ? handleLocation
    : body.action === "phone_taps"
    ? handlePhoneTap
    : null;
  if (!handler || !Array.isArray(body.items) || body.items.length > MAX_ITEMS) {
    return json({ error: "INVALID_REQUEST" }, 400);
  }

  const results: Result[] = [];
  for (const raw of body.items) {
    const item = (raw ?? {}) as Item;
    const uploadId = typeof item.upload_id === "string" ? item.upload_id : null;
    try {
      const result = await handler(userId, item);
      results.push({ ...result, upload_id: uploadId });
    } catch (error) {
      results.push(
        error instanceof Reject
          ? { upload_id: uploadId, status: "rejected", code: error.code }
          // Database or network trouble: the phone keeps it and retries.
          : { upload_id: uploadId, status: "error" },
      );
    }
  }
  return json({ results });
});
