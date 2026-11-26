package com.example.comptech_portal_app;

import android.app.KeyguardManager;
import android.content.Context;
import android.content.SharedPreferences;
import android.nfc.NfcAdapter;
import android.os.PowerManager;
import android.os.SystemClock;
import java.util.HashMap;
import java.util.Map;
import java.util.UUID;

public final class PhoneNfcState {
    private static SharedPreferences prefs(Context c) {
        return c.getSharedPreferences("comptech_phone_nfc_v1",Context.MODE_PRIVATE);
    }
    public static void enable(Context c,String student,String fingerprint) {
        if(!UUID.fromString(student).toString().equals(student) || !fingerprint.matches("[0-9a-f]{64}"))
            throw new IllegalArgumentException("Invalid credential");
        NfcAdapter adapter=NfcAdapter.getDefaultAdapter(c);
        if(adapter==null || !adapter.isEnabled()) throw new IllegalStateException("Enable NFC first");
        if(!c.getPackageManager().hasSystemFeature("android.hardware.nfc.hce"))
            throw new IllegalStateException("HCE is unavailable");
        long now=System.currentTimeMillis(), elapsed=SystemClock.elapsedRealtime();
        prefs(c).edit().clear().putString("student",student).putString("fingerprint",fingerprint)
                .putLong("expires",now+10*60*1000).putLong("started_elapsed",elapsed)
                .putLong("expires_elapsed",elapsed+10*60*1000).putString("status","Ready for a compatible phone-NFC reader.")
                .apply();
    }
    public static void disable(Context c) { prefs(c).edit().clear().apply(); }
    public static String student(Context c) { return prefs(c).getString("student",""); }
    public static String fingerprint(Context c) { return prefs(c).getString("fingerprint",""); }
    public static boolean armed(Context c) {
        SharedPreferences p=prefs(c); long elapsed=SystemClock.elapsedRealtime();
        return !student(c).isEmpty() && System.currentTimeMillis()<p.getLong("expires",0)
                && elapsed>=p.getLong("started_elapsed",Long.MAX_VALUE)
                && elapsed<p.getLong("expires_elapsed",0);
    }
    public static boolean available(Context c) {
        KeyguardManager k=(KeyguardManager)c.getSystemService(Context.KEYGUARD_SERVICE);
        PowerManager p=(PowerManager)c.getSystemService(Context.POWER_SERVICE);
        NfcAdapter n=NfcAdapter.getDefaultAdapter(c);
        return armed(c) && k!=null && !k.isKeyguardLocked() && p!=null && p.isInteractive()
                && n!=null && n.isEnabled();
    }
    public static void proofSent(Context c) {
        // proof_at lets the app tell each tap apart; the message stays the same.
        prefs(c).edit().putString("status","NFC proof prepared. Attendance is not confirmed; check Attendance History after the reader submits it.")
                .putLong("proof_at",System.currentTimeMillis()).apply();
    }
    public static Map<String,Object> status(Context c) {
        Map<String,Object> result=new HashMap<>();
        result.put("enabled",armed(c)); result.put("student_id",student(c));
        result.put("expires_at",prefs(c).getLong("expires",0));
        result.put("message",prefs(c).getString("status","Phone NFC is off."));
        result.put("proof_at",prefs(c).getLong("proof_at",0));
        return result;
    }
}
