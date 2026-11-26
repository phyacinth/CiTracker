package com.example.comptech_portal_app;

import android.nfc.cardemulation.HostApduService;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.Base64;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public final class PhoneNfcService extends HostApduService {
    private final ExecutorService worker=Executors.newSingleThreadExecutor();
    private final Handler main=new Handler(Looper.getMainLooper());
    private int generation=0;
    private boolean pending=false;
    private PhoneNfcProtocol protocol;

    @Override public byte[] processCommandApdu(byte[] command,Bundle extras) {
        if(pending) return PhoneNfcProtocol.sw(0x6985);
        if(!PhoneNfcState.available(this)) return PhoneNfcProtocol.sw(0x6985);
        if(protocol==null) {
            final String student=PhoneNfcState.student(this), fingerprint=PhoneNfcState.fingerprint(this);
            protocol=new PhoneNfcProtocol(new PhoneNfcProtocol.Credential() {
                public String studentId(){return student;}
                public String fingerprint(){return fingerprint;}
                public boolean available(){return PhoneNfcState.available(PhoneNfcService.this)
                        && student.equals(PhoneNfcState.student(PhoneNfcService.this))
                        && fingerprint.equals(PhoneNfcState.fingerprint(PhoneNfcService.this));}
                public long epochSeconds(){return System.currentTimeMillis()/1000;}
                public byte[] sign(String message) throws Exception {
                    String signature=NfcPhoneKeyStore.INSTANCE.signPhoneTapChallenge(student,fingerprint,message);
                    if(!available()) throw new IllegalStateException("Phone NFC disabled");
                    PhoneNfcState.proofSent(PhoneNfcService.this);
                    return Base64.decode(signature,Base64.NO_WRAP);
                }
            });
        }
        final int epoch=generation;
        final PhoneNfcProtocol engine=protocol;
        final byte[] copy=command==null?null:command.clone();
        pending=true;
        worker.execute(()->{
            byte[] answer;
            try { answer=engine.exchange(copy); }
            catch(Exception error){answer=PhoneNfcProtocol.sw(0x6F00);}
            final byte[] response=answer;
            main.post(()->{
                if(epoch==generation){pending=false;sendResponseApdu(response);}
            });
        });
        return null;
    }
    @Override public void onDeactivated(int reason){generation++;pending=false;protocol=null;}
    @Override public void onDestroy(){generation++;worker.shutdownNow();super.onDestroy();}
}
