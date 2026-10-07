// IZeroTierService.aidl
package com.quix.zerotier;

import com.quix.zerotier.IZeroTierCallback;

interface IZeroTierService {
    void joinNetwork(long networkId);
    void leaveNetwork(long networkId);
    void stopZeroTier();
    void setCallback(IZeroTierCallback callback);
}
