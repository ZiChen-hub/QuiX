/*
 * This file is derived from ZerotierFix (https://github.com/kaaass/ZerotierFix),
 * licensed under the GPL-2.0 License. See LICENSE in this module for details.
 */
package com.quix.zerotier;

import java.net.InetAddress;

/**
 * ARP 表项。记录 MAC 与 IPv4 地址的对应关系及记录时间
 */
public class ARPEntry {
    private final long mac;
    private final InetAddress address;
    private long time;

    ARPEntry(long mac, InetAddress inetAddress) {
        this.mac = mac;
        this.address = inetAddress;
        updateTime();
    }

    public long getMac() {
        return mac;
    }

    public InetAddress getAddress() {
        return address;
    }

    public long getTime() {
        return time;
    }

    public void updateTime() {
        this.time = System.currentTimeMillis();
    }
}
