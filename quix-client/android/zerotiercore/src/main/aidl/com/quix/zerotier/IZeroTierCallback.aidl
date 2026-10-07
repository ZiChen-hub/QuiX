// IZeroTierCallback.aidl
package com.quix.zerotier;

interface IZeroTierCallback {
    void onNodeUp(long nodeAddress);
    void onNetworkStatus(long networkId, int status, String assignedIp);
    void onFatalError(String message);
}
