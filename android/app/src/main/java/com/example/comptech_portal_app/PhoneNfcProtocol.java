package com.example.comptech_portal_app;

import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.UUID;

/** Pure protocol logic. A reader is not an authority; the backend must validate the proof. */
public final class PhoneNfcProtocol {
    public static final byte[] AID = hex("F0434F4D505445434801");
    public interface Credential {
        String studentId();
        String fingerprint();
        boolean available();
        byte[] sign(String message) throws Exception;
        long epochSeconds();
    }
    private final Credential credential;
    private boolean selected;
    private boolean uploading;
    private int sequence;
    private final ByteArrayOutputStream input = new ByteArrayOutputStream();
    private byte[] proof;

    public PhoneNfcProtocol(Credential credential) { this.credential = credential; }
    public byte[] exchange(byte[] apdu) {
        if (apdu == null || apdu.length < 4) return sw(0x6700);
        // SELECT by exact private application identifier. Optional one-byte Le is accepted.
        if ((apdu[0]&255)==0 && (apdu[1]&255)==0xA4) {
            selected=false; uploading=false; input.reset(); proof=null; sequence=0;
            if ((apdu[2]&255)!=4 || (apdu[3]&255)!=0 || apdu.length<5) return sw(0x6A86);
            int n=apdu[4]&255;
            if (n!=AID.length || (apdu.length!=5+n && apdu.length!=6+n)) return sw(0x6700);
            if (!Arrays.equals(Arrays.copyOfRange(apdu,5,5+n),AID)) return sw(0x6A82);
            if (!credential.available()) return sw(0x6985);
            selected=true;
            return response(new byte[]{1});
        }
        if (!selected || !credential.available()) return sw(0x6985);
        if ((apdu[0]&255)!=0x80) return sw(0x6E00);
        int ins=apdu[1]&255;
        if (ins!=0x21 && (apdu[2]!=0 || apdu[3]!=0)) return sw(0x6A86);
        if (ins!=0x21 && !(apdu.length==4 || (apdu.length==5 && apdu[4]==0))) return sw(0x6700);
        if (ins==0x10) {
            String json="{\"version\":1,\"student_id\":\""+credential.studentId()+
                    "\",\"key_fingerprint\":\""+credential.fingerprint()+"\"}";
            return response(json.getBytes(StandardCharsets.UTF_8));
        }
        if (ins==0x20) {
            input.reset(); sequence=0; uploading=true; proof=null;
            return sw(0x9000);
        }
        if (ins==0x21) {
            if (!uploading || apdu[3]!=0 || (apdu[2]&255)!=sequence) return sw(0x6985);
            if (apdu.length<5) return sw(0x6700);
            int n=apdu[4]&255;
            if(n==0 || n>220 || apdu.length!=5+n || input.size()+n>1024) return sw(0x6700);
            input.write(apdu,5,n); sequence++;
            return sw(0x9000);
        }
        if (ins==0x22) {
            if (proof!=null) return response(proof);
            if (!uploading) return sw(0x6985);
            byte[] bytes=input.toByteArray();
            for(byte b:bytes) if((b&255)>127) return sw(0x6A80);
            String message=new String(bytes,StandardCharsets.US_ASCII);
            try {
                validate(message,credential.studentId(),credential.fingerprint(),credential.epochSeconds());
                if (!credential.available()) return sw(0x6985);
                proof=credential.sign(message);
                uploading=false; input.reset();
                return response(proof);
            } catch(Exception error) { input.reset(); uploading=false; return sw(0x6A80); }
        }
        return sw(0x6D00);
    }
    public static void validate(String message,String student,String fingerprint,long now) {
        String[] line=message.split("\n",-1);
        if(line.length!=9 || !line[0].equals("COMPTECH:NFC:PHONE_TAP:V1") ||
                !line[1].equals("student="+student) || !line[2].equals("key="+fingerprint))
            throw new IllegalArgumentException("Wrong phone or domain");
        String[] names={"challenge=","session=","class=","scanner="};
        for(int i=0;i<names.length;i++) {
            String value=line[i+3];
            if(!value.startsWith(names[i])) throw new IllegalArgumentException("Missing context");
            String id=value.substring(names[i].length());
            if(!UUID.fromString(id).toString().equals(id)) throw new IllegalArgumentException("Invalid ID");
        }
        if(!line[7].matches("nonce=[0-9a-f]{64}") || !line[8].matches("expires=[0-9]{10}"))
            throw new IllegalArgumentException("Invalid freshness fields");
        long expiry=Long.parseLong(line[8].substring(8));
        if(expiry<=now || expiry>now+60) throw new IllegalArgumentException("Expired or excessive lifetime");
    }
    public static byte[] sw(int status) { return new byte[]{(byte)(status>>8),(byte)status}; }
    private static byte[] response(byte[] value) {
        byte[] out=Arrays.copyOf(value,value.length+2); out[value.length]=(byte)0x90; return out;
    }
    private static byte[] hex(String text) {
        byte[] out=new byte[text.length()/2];
        for(int i=0;i<out.length;i++)out[i]=(byte)Integer.parseInt(text.substring(i*2,i*2+2),16);
        return out;
    }
}
