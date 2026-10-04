/*
 * This file is derived from ZerotierFix (https://github.com/kaaass/ZerotierFix),
 * licensed under the GPL-2.0 License. See LICENSE in this module for details.
 */
package com.quix.zerotier;

import com.quix.zerotier.util.InetAddressUtils;

import java.net.InetAddress;

/**
 * 路由记录数据类
 */
public class Route {
    private final InetAddress address;
    private final int prefix;
    private InetAddress gateway = null;

    public Route(InetAddress address, int prefix) {
        this.address = address;
        this.prefix = prefix;
    }

    public InetAddress getAddress() {
        return address;
    }

    public int getPrefix() {
        return prefix;
    }

    public InetAddress getGateway() {
        return gateway;
    }

    public void setGateway(InetAddress gateway) {
        this.gateway = gateway;
    }

    public boolean belongsToRoute(InetAddress inetAddress) {
        return this.address.equals(InetAddressUtils.addressToRoute(inetAddress, this.prefix));
    }
}
