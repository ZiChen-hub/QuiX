/*
 * This file is derived from ZerotierFix (https://github.com/kaaass/ZerotierFix),
 * licensed under the GPL-2.0 License. See LICENSE in this module for details.
 */
package com.quix.zerotier;

import java.net.InetAddress;

/**
 * ARP 应答报文的所需数据。由于报文内容总是当前节点的 IP 与 MAC，因此仅记录应答报文目标的信息。
 */
public class ARPReplyData {
    private final long destMac;
    private final InetAddress destAddress;

    ARPReplyData(long destMac, InetAddress destAddress) {
        this.destMac = destMac;
        this.destAddress = destAddress;
    }

    public long getDestMac() {
        return destMac;
    }

    public InetAddress getDestAddress() {
        return destAddress;
    }
}
