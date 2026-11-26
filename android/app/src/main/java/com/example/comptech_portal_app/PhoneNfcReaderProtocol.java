package com.example.comptech_portal_app;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;

/** Reader counterpart of PhoneNfcProtocol. No Android dependencies. */
public final class PhoneNfcReaderProtocol {
    public interface Transport { byte[] exchange(byte[] command) throws IOException; }
    private final Transport transport;
    public PhoneNfcReaderProtocol(Transport transport) { this.transport = transport; }
    private byte[] command(byte[] command) throws IOException {
        byte[] response = transport.exchange(command);
        if (response == null || response.length < 2 || response.length > 2048)
            throw new IOException("Invalid NFC response. Hold both phones together and retry.");
        int n = response.length;
        int status = ((response[n-2] & 255) << 8) | (response[n-1] & 255);
        if (status != 0x9000) {
            if (status == 0x6985) throw new IOException("Enable Phone NFC on the registered student phone and keep it unlocked.");
            if (status == 0x6A80) throw new IOException("Phone rejected the challenge. Check automatic date/time on both phones, refresh the session, and retry.");
            if (status == 0x6A82) throw new IOException("This is not a CompTech phone credential.");
            throw new IOException("Phone NFC protocol failed (" + Integer.toHexString(status) + "). Retry the tap.");
        }
        return Arrays.copyOf(response, n-2);
    }
    public String readIdentity() throws IOException {
        byte[] aid = PhoneNfcProtocol.AID;
        byte[] select = new byte[5 + aid.length];
        select[1] = (byte)0xA4; select[2] = 4; select[4] = (byte)aid.length;
        System.arraycopy(aid, 0, select, 5, aid.length);
        byte[] version = command(select);
        if (version.length != 1 || version[0] != 1) throw new IOException("Unsupported CompTech NFC version.");
        byte[] identity = command(new byte[]{(byte)0x80,0x10,0,0,0});
        if (identity.length == 0 || identity.length > 512) throw new IOException("Invalid phone identity.");
        for (byte b: identity) if ((b & 255)>127) throw new IOException("Invalid phone identity.");
        return new String(identity, StandardCharsets.US_ASCII);
    }
    public byte[] sign(String message) throws IOException {
        if (message == null || message.isEmpty() || message.length() > 1024)
            throw new IOException("Invalid server challenge.");
        for (int i=0; i<message.length(); i++) if (message.charAt(i)>127) throw new IOException("Invalid server challenge.");
        byte[] bytes = message.getBytes(StandardCharsets.US_ASCII);
        command(new byte[]{(byte)0x80,0x20,0,0,0});
        int sequence = 0;
        for (int offset=0; offset<bytes.length; offset+=220) {
            int length = Math.min(220, bytes.length-offset);
            byte[] chunk = new byte[5+length];
            chunk[0]=(byte)0x80; chunk[1]=0x21; chunk[2]=(byte)sequence++; chunk[4]=(byte)length;
            System.arraycopy(bytes,offset,chunk,5,length); command(chunk);
        }
        byte[] signature = command(new byte[]{(byte)0x80,0x22,0,0,0});
        if (signature.length<8 || signature.length>72 || signature[0]!=0x30 || (signature[1]&255)!=signature.length-2)
            throw new IOException("Invalid phone signature response.");
        return signature;
    }
}
