/*
 * This file is derived from ZerotierFix (https://github.com/kaaass/ZerotierFix),
 * licensed under the GPL-2.0 License. See LICENSE in this module for details.
 */
package com.quix.zerotier;

import android.util.Log;

import com.quix.zerotier.util.IPPacketUtils;

import java.net.InetAddress;
import java.nio.ByteBuffer;
import java.util.HashMap;

/**
 * IPv6 NDP（邻居发现）表，维护 IP 与 MAC 的映射并定时清理过期表项
 */
public class NDPTable {
    public static final String TAG = "NDPTable";
    private static final long ENTRY_TIMEOUT = 120000;
    private final HashMap<Long, NDPEntry> entriesMap = new HashMap<>();
    private final HashMap<InetAddress, Long> inetAddressToMacAddress = new HashMap<>();
    private final HashMap<InetAddress, NDPEntry> ipEntriesMap = new HashMap<>();
    private final HashMap<Long, InetAddress> macAddressToInetAddress = new HashMap<>();
    private final Thread timeoutThread = new Thread("NDP Timeout Thread") {
        @Override
        public void run() {
            while (!isInterrupted()) {
                try {
                    for (NDPEntry nDPEntry : new HashMap<>(NDPTable.this.entriesMap).values()) {
                        if (nDPEntry.getTime() + NDPTable.ENTRY_TIMEOUT < System.currentTimeMillis()) {
                            synchronized (NDPTable.this.macAddressToInetAddress) {
                                NDPTable.this.macAddressToInetAddress.remove(nDPEntry.getMac());
                            }
                            synchronized (NDPTable.this.inetAddressToMacAddress) {
                                NDPTable.this.inetAddressToMacAddress.remove(nDPEntry.getAddress());
                            }
                            synchronized (NDPTable.this.entriesMap) {
                                NDPTable.this.entriesMap.remove(nDPEntry.getMac());
                            }
                            synchronized (NDPTable.this.ipEntriesMap) {
                                NDPTable.this.ipEntriesMap.remove(nDPEntry.getAddress());
                            }
                        }
                    }
                    Thread.sleep(1000);
                } catch (Exception e) {
                    Log.d(NDPTable.TAG, e.toString());
                    return;
                }
            }
        }
    };

    public NDPTable() {
        this.timeoutThread.start();
    }

    public void stop() {
        try {
            this.timeoutThread.interrupt();
            this.timeoutThread.join();
        } catch (InterruptedException ignored) {
        }
    }

    public void setAddress(InetAddress inetAddress, long j) {
        synchronized (this.inetAddressToMacAddress) {
            this.inetAddressToMacAddress.put(inetAddress, j);
        }
        synchronized (this.macAddressToInetAddress) {
            this.macAddressToInetAddress.put(j, inetAddress);
        }
        NDPEntry nDPEntry = new NDPEntry(j, inetAddress);
        synchronized (this.entriesMap) {
            this.entriesMap.put(j, nDPEntry);
        }
        synchronized (this.ipEntriesMap) {
            this.ipEntriesMap.put(inetAddress, nDPEntry);
        }
    }

    public boolean hasMacForAddress(InetAddress inetAddress) {
        boolean containsKey;
        synchronized (this.inetAddressToMacAddress) {
            containsKey = this.inetAddressToMacAddress.containsKey(inetAddress);
        }
        return containsKey;
    }

    public boolean hasAddressForMac(long j) {
        boolean containsKey;
        synchronized (this.macAddressToInetAddress) {
            containsKey = this.macAddressToInetAddress.containsKey(j);
        }
        return containsKey;
    }

    public long getMacForAddress(InetAddress inetAddress) {
        synchronized (this.inetAddressToMacAddress) {
            if (!this.inetAddressToMacAddress.containsKey(inetAddress)) {
                return -1;
            }
            long longValue = this.inetAddressToMacAddress.get(inetAddress);
            updateNDPEntryTime(longValue);
            return longValue;
        }
    }

    public InetAddress getAddressForMac(long j) {
        synchronized (this.macAddressToInetAddress) {
            if (!this.macAddressToInetAddress.containsKey(j)) {
                return null;
            }
            InetAddress inetAddress = this.macAddressToInetAddress.get(j);
            updateNDPEntryTime(inetAddress);
            return inetAddress;
        }
    }

    private void updateNDPEntryTime(InetAddress inetAddress) {
        synchronized (this.ipEntriesMap) {
            NDPEntry nDPEntry = this.ipEntriesMap.get(inetAddress);
            if (nDPEntry != null) {
                nDPEntry.updateTime();
            }
        }
    }

    private void updateNDPEntryTime(long j) {
        synchronized (this.entriesMap) {
            NDPEntry nDPEntry = this.entriesMap.get(j);
            if (nDPEntry != null) {
                nDPEntry.updateTime();
            }
        }
    }

    /**
     * 构造 IPv6 邻居请求（NS）报文
     */
    public byte[] getNeighborSolicitationPacket(InetAddress inetAddress, InetAddress inetAddress2, long j) {
        byte[] bArr = new byte[72];
        System.arraycopy(inetAddress.getAddress(), 0, bArr, 0, 16);
        System.arraycopy(inetAddress2.getAddress(), 0, bArr, 16, 16);
        System.arraycopy(ByteBuffer.allocate(4).putInt(32).array(), 0, bArr, 32, 4);
        bArr[39] = 58;
        bArr[40] = -121;
        System.arraycopy(inetAddress2.getAddress(), 0, bArr, 48, 16);
        byte[] array = ByteBuffer.allocate(8).putLong(j).array();
        bArr[64] = 1;
        bArr[65] = 1;
        System.arraycopy(array, 2, bArr, 66, 6);
        System.arraycopy(ByteBuffer.allocate(2).putShort((short) ((int) IPPacketUtils.calculateChecksum(bArr, 0, 0, 72))).array(), 0, bArr, 42, 2);
        for (int i = 0; i < 40; i++) {
            bArr[i] = 0;
        }
        bArr[0] = 96;
        System.arraycopy(ByteBuffer.allocate(2).putShort((short) 32).array(), 0, bArr, 4, 2);
        bArr[6] = 58;
        bArr[7] = -1;
        System.arraycopy(inetAddress.getAddress(), 0, bArr, 8, 16);
        System.arraycopy(inetAddress2.getAddress(), 0, bArr, 24, 16);
        return bArr;
    }
}
