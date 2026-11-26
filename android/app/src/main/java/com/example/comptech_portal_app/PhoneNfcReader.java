package com.example.comptech_portal_app;

import android.app.Activity;
import android.nfc.NfcAdapter;
import android.nfc.Tag;
import android.nfc.tech.IsoDep;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.Base64;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import java.io.IOException;
import java.util.HashMap;
import java.util.Map;
import java.util.UUID;
import org.json.JSONObject;

/** Foreground faculty reader. Stops on activity pause; never creates student keys. */
public final class PhoneNfcReader implements MethodChannel.MethodCallHandler {
    private final Activity activity;
    private final Handler main = new Handler(Looper.getMainLooper());
    private NfcAdapter adapter;
    private volatile IsoDep connection;
    private PhoneNfcReaderProtocol protocol;
    private int generation;
    private boolean detecting, signing, running;
    private MethodChannel.Result pending;
    private Runnable deadline;

    public PhoneNfcReader(Activity activity) { this.activity=activity; }
    @Override public void onMethodCall(MethodCall call, MethodChannel.Result result) {
        if (call.method.equals("stop")) { stop(); result.success(null); return; }
        if (call.method.equals("start")) { start(result); return; }
        if (call.method.equals("sign")) {
            String message=call.argument("message");
            sign(message,result); return;
        }
        result.notImplemented();
    }
    // All state transitions run on the Android main thread. Only I/O uses workers.
    private void start(MethodChannel.Result result) {
        stop();
        adapter=NfcAdapter.getDefaultAdapter(activity);
        if(adapter==null || !adapter.isEnabled()) {
            result.error("PHONE_READER_ERROR","Enable NFC on the faculty phone.",null); return;
        }
        // The scanner phone is a reader for this operation, never a student credential.
        PhoneNfcState.disable(activity);
        running=true; pending=result; final int ticket=++generation;
        deadline=() -> fail(ticket,"Phone scan timed out. Keep both phones unlocked, enable student Phone NFC, and try again.");
        main.postDelayed(deadline,60000);
        Bundle options=new Bundle();
        options.putInt(NfcAdapter.EXTRA_READER_PRESENCE_CHECK_DELAY,250);
        try {
            adapter.enableReaderMode(activity, tag -> main.post(() -> discover(ticket,tag)),
                    NfcAdapter.FLAG_READER_NFC_A | NfcAdapter.FLAG_READER_SKIP_NDEF_CHECK,options);
        } catch(Exception error) { fail(ticket,"Could not start NFC reader mode. Keep this screen open and enable NFC."); }
    }
    private void discover(int ticket, Tag tag) {
        if(ticket!=generation || !running || detecting || protocol!=null) return;
        detecting=true;
        IsoDep iso=IsoDep.get(tag);
        if(iso==null) { fail(ticket,"Tap the registered student phone, not a physical card."); return; }
        connection=iso;
        new Thread(() -> {
            try {
                iso.connect(); iso.setTimeout(10000);
                PhoneNfcReaderProtocol reader=new PhoneNfcReaderProtocol(iso::transceive);
                JSONObject identity=new JSONObject(reader.readIdentity());
                String student=identity.getString("student_id"), fp=identity.getString("key_fingerprint");
                if(identity.getInt("version")!=1 || !UUID.fromString(student).toString().equals(student)
                        || !fp.matches("[0-9a-f]{64}")) throw new IOException("Invalid student phone identity.");
                Map<String,Object> response=new HashMap<>();
                response.put("student_id",student); response.put("key_fingerprint",fp);
                main.post(() -> {
                    if(ticket!=generation || !running) { close(iso); return; }
                    protocol=reader; detecting=false;
                    MethodChannel.Result callback=pending; pending=null;
                    if(callback!=null) callback.success(response);
                });
            } catch(Exception error) {
                close(iso);
                main.post(() -> fail(ticket, error instanceof IOException ? error.getMessage() : "Could not read the student phone. Hold both phones together and retry."));
            }
        },"phone-nfc-identify").start();
    }
    private void sign(String message, MethodChannel.Result result) {
        if(!running || protocol==null || signing || pending!=null) {
            result.error("PHONE_READER_ERROR","Phone connection ended. Start a new scan and keep the phones together.",null); return;
        }
        final int ticket=generation;
        final PhoneNfcReaderProtocol reader=protocol;
        signing=true; pending=result;
        new Thread(() -> {
            try {
                String signature=Base64.encodeToString(reader.sign(message),Base64.NO_WRAP);
                main.post(() -> {
                    if(ticket!=generation || !running) return;
                    MethodChannel.Result callback=pending; pending=null;
                    shutdown();
                    if(callback!=null) callback.success(signature);
                });
            } catch(Exception error) {
                main.post(() -> fail(ticket,error instanceof IOException ? error.getMessage() : "Phone signature could not be read. Hold both phones together and retry."));
            }
        },"phone-nfc-sign").start();
    }
    private void fail(int ticket, String message) {
        if(ticket!=generation) return;
        MethodChannel.Result callback=pending; pending=null;
        shutdown();
        if(callback!=null) callback.error("PHONE_READER_ERROR",message==null ? "NFC connection lost. Retry the tap." : message,null);
    }
    private void shutdown() {
        running=false; generation++; protocol=null; detecting=false; signing=false;
        if(deadline!=null) { main.removeCallbacks(deadline); deadline=null; }
        try { if(adapter!=null) adapter.disableReaderMode(activity); } catch(Exception ignored) { }
        IsoDep old=connection; connection=null;
        if(old!=null) new Thread(() -> close(old),"phone-nfc-close").start();
    }
    private static void close(IsoDep iso) { try { iso.close(); } catch(Exception ignored) { } }
    public void stop() {
        MethodChannel.Result callback=pending; pending=null;
        shutdown();
        if(callback!=null) callback.error("PHONE_READER_ERROR","Phone scan stopped. Check attendance history if a submission was in progress.",null);
    }
}
