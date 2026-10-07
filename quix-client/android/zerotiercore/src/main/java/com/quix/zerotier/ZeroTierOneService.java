/*
 * This file is derived from ZerotierFix (https://github.com/kaaass/ZerotierFix),
 * licensed under the GPL-2.0 License. See LICENSE in this module for details.
 */
package com.quix.zerotier;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.net.VpnService;
import android.os.Binder;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.ParcelFileDescriptor;
import android.util.Log;

import com.zerotier.sdk.Event;
import com.zerotier.sdk.EventListener;
import com.zerotier.sdk.Node;
import com.zerotier.sdk.ResultCode;
import com.zerotier.sdk.VirtualNetworkConfig;
import com.zerotier.sdk.VirtualNetworkConfigListener;
import com.zerotier.sdk.VirtualNetworkConfigOperation;
import com.zerotier.sdk.VirtualNetworkDNS;
import com.zerotier.sdk.VirtualNetworkRoute;
import com.zerotier.sdk.VirtualNetworkStatus;

import com.quix.zerotier.util.InetAddressUtils;

import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.net.DatagramSocket;
import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.nio.ByteBuffer;
import java.util.HashMap;
import java.util.Map;

/**
 * QuiX 内嵌 ZeroTier 节点的 VPN 服务。
 * 负责节点生命周期、TUN 配置、网络加入与状态回调。
 */
public class ZeroTierOneService extends VpnService
        implements Runnable, EventListener, VirtualNetworkConfigListener {

    /** Intent extra：64 位网络 ID（long） */
    public static final String EXTRA_NETWORK_ID = "com.quix.zerotier.network_id";

    private static final String TAG = "QuiXZTService";
    private static final int NOTIFICATION_ID = 5919812;
    private static final String CHANNEL_ID = "quix_zerotier";
    private static final String CHANNEL_NAME = "QuiX ZeroTier 组网";
    private static final String VPN_SESSION_NAME = "QuiX ZeroTier";
    private static final String[] DISALLOWED_APPS = {"com.android.vending"};

    private final DataStore dataStore = new DataStore(this);
    private final Map<Long, VirtualNetworkConfig> virtualNetworkConfigMap = new HashMap<>();
    private final Handler mainHandler = new Handler(Looper.getMainLooper());

    private long networkId = 0;
    private long nextBackgroundTaskDeadline = 0;
    private int mStartID = -1;
    private Node node;
    private DatagramSocket svrSocket;
    private UdpCom udpCom;
    private TunTapAdapter tunTapAdapter;
    private Thread udpThread;
    private Thread vpnThread;
    ParcelFileDescriptor vpnSocket;
    FileInputStream in;
    FileOutputStream out;
    private NotificationManager notificationManager;
    private volatile IZeroTierCallback statusListener;

    // ---- AIDL 跨进程接口实现 ----

    private final IZeroTierService.Stub mBinder = new IZeroTierService.Stub() {
        @Override
        public void joinNetwork(long networkId) {
            ZeroTierOneService.this.joinNetwork(networkId);
        }

        @Override
        public void leaveNetwork(long networkId) {
            ZeroTierOneService.this.leaveNetwork(networkId);
        }

        @Override
        public void stopZeroTier() {
            ZeroTierOneService.this.stopZeroTier();
        }

        @Override
        public void setCallback(IZeroTierCallback callback) {
            ZeroTierOneService.this.statusListener = callback;
        }
    };

    @Override
    public IBinder onBind(Intent intent) {
        Log.d(TAG, "Bound (AIDL)");
        return mBinder;
    }

    @Override
    public boolean onUnbind(Intent intent) {
        return false;
    }

    void setNextBackgroundTaskDeadline(long deadline) {
        synchronized (this) {
            this.nextBackgroundTaskDeadline = deadline;
        }
    }

    VirtualNetworkConfig getVirtualNetworkConfig(long nwid) {
        synchronized (virtualNetworkConfigMap) {
            return virtualNetworkConfigMap.get(nwid);
        }
    }

    private VirtualNetworkConfig putVirtualNetworkConfig(long nwid, VirtualNetworkConfig config) {
        synchronized (virtualNetworkConfigMap) {
            return virtualNetworkConfigMap.put(nwid, config);
        }
    }

    private VirtualNetworkConfig removeVirtualNetworkConfig(long nwid) {
        synchronized (virtualNetworkConfigMap) {
            return virtualNetworkConfigMap.remove(nwid);
        }
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        Log.d(TAG, "onStartCommand");
        if (intent == null) {
            return START_NOT_STICKY;
        }
        long nwid = intent.getLongExtra(EXTRA_NETWORK_ID, 0);
        if (nwid == 0) {
            Log.e(TAG, "Network ID not provided to service");
            stopSelf(startId);
            return START_NOT_STICKY;
        }
        this.mStartID = startId;
        this.networkId = nwid;

        // 以前台服务启动（API 34+ 使用 specialUse 类型）
        startAsForeground("ZeroTier 组网启动中…");

        synchronized (this) {
            try {
                if (this.node == null) {
                    // 创建本地 UDP socket（ZeroTier 默认端口 9994）并 protect，避免流量被 VPN 捕获形成环路
                    this.svrSocket = new DatagramSocket(null);
                    this.svrSocket.setReuseAddress(true);
                    this.svrSocket.setSoTimeout(1000);
                    this.svrSocket.bind(new InetSocketAddress(9994));
                    if (!protect(this.svrSocket)) {
                        Log.e(TAG, "Error protecting UDP socket from feedback loop.");
                    }

                    this.udpCom = new UdpCom(this, this.svrSocket);
                    this.tunTapAdapter = new TunTapAdapter(this, nwid);

                    // 创建并初始化节点（首次会生成身份，可能耗时数秒）
                    this.node = new Node(System.currentTimeMillis());
                    ResultCode result = this.node.init(
                            dataStore, dataStore, udpCom, this, tunTapAdapter, this, null);
                    if (result != ResultCode.RESULT_OK) {
                        Log.e(TAG, "Error starting ZT node: " + result);
                        notifyFatal("ZeroTier 节点启动失败: " + result);
                        stopSelf(startId);
                        return START_NOT_STICKY;
                    }
                    Log.d(TAG, "ZeroTier node initialized");
                    notifyNodeUp(this.node.address());
                    this.udpCom.setNode(this.node);
                    this.tunTapAdapter.setNode(this.node);

                    this.udpThread = new Thread(this.udpCom, "UDP Communication Thread");
                    this.udpThread.start();
                }
                if (this.vpnThread == null) {
                    this.vpnThread = new Thread(this, "ZeroTier Service Thread");
                    this.vpnThread.start();
                }
            } catch (Exception e) {
                Log.e(TAG, e.toString(), e);
                notifyFatal(e.toString());
                stopSelf(startId);
                return START_NOT_STICKY;
            }
        }
        joinNetwork(nwid);
        return START_STICKY;
    }

    //
    // 前台服务与通知
    //

    private void startAsForeground(String text) {
        try {
            if (notificationManager == null) {
                notificationManager = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
            }
            if (Build.VERSION.SDK_INT >= 26) {
                NotificationChannel channel = new NotificationChannel(
                        CHANNEL_ID, CHANNEL_NAME, NotificationManager.IMPORTANCE_LOW);
                notificationManager.createNotificationChannel(channel);
            }
            Notification notification = buildNotification(text);
            if (Build.VERSION.SDK_INT >= 34) {
                startForeground(NOTIFICATION_ID, notification,
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE);
            } else {
                startForeground(NOTIFICATION_ID, notification);
            }
        } catch (Exception e) {
            Log.e(TAG, "startForeground failed", e);
        }
    }

    private Notification buildNotification(String text) {
        Notification.Builder builder;
        if (Build.VERSION.SDK_INT >= 26) {
            builder = new Notification.Builder(this, CHANNEL_ID);
        } else {
            builder = new Notification.Builder(this);
        }
        builder.setSmallIcon(android.R.drawable.ic_dialog_info)
                .setContentTitle("QuiX ZeroTier")
                .setContentText(text)
                .setOngoing(true);
        // 点击通知回到应用主界面
        Intent launchIntent = getPackageManager().getLaunchIntentForPackage(getPackageName());
        if (launchIntent != null) {
            int flags = PendingIntent.FLAG_UPDATE_CURRENT;
            if (Build.VERSION.SDK_INT >= 31) {
                flags |= PendingIntent.FLAG_IMMUTABLE;
            }
            builder.setContentIntent(PendingIntent.getActivity(this, 0, launchIntent, flags));
        }
        return builder.build();
    }

    //
    // 节点后台任务线程
    //

    @Override
    public void run() {
        Log.d(TAG, "ZeroTier service started");
        while (!Thread.interrupted()) {
            try {
                long deadline;
                synchronized (this) {
                    deadline = this.nextBackgroundTaskDeadline;
                }
                long now = System.currentTimeMillis();
                long waitMs = deadline - now;
                if (waitMs <= 0) {
                    long[] newDeadline = {0};
                    ResultCode result = node.processBackgroundTasks(now, newDeadline);
                    synchronized (this) {
                        this.nextBackgroundTaskDeadline = newDeadline[0];
                    }
                    if (result != ResultCode.RESULT_OK) {
                        Log.e(TAG, "processBackgroundTasks: " + result);
                        notifyFatal("ZeroTier 后台任务异常: " + result);
                        shutdown();
                    }
                    waitMs = 100;
                }
                Thread.sleep(waitMs);
            } catch (InterruptedException e) {
                break;
            } catch (Exception e) {
                Log.e(TAG, e.toString(), e);
            }
        }
        Log.d(TAG, "ZeroTier service ended");
    }

    /**
     * 加入 ZT 网络
     */
    public void joinNetwork(long nwid) {
        Node current = this.node;
        if (current == null) {
            Log.e(TAG, "Can't join network if ZeroTier isn't running");
            return;
        }
        ResultCode result = current.join(nwid);
        if (result != ResultCode.RESULT_OK) {
            Log.e(TAG, "join failed: " + result);
            notifyFatal("加入网络失败: " + result);
        }
    }

    /**
     * 离开 ZT 网络；若已不在任何网络则停止服务
     */
    public void leaveNetwork(long nwid) {
        Node current = this.node;
        if (current == null) {
            Log.e(TAG, "Can't leave network if ZeroTier isn't running");
            return;
        }
        ResultCode result = current.leave(nwid);
        if (result != ResultCode.RESULT_OK) {
            Log.e(TAG, "leave failed: " + result);
            notifyFatal("离开网络失败: " + result);
            return;
        }
        VirtualNetworkConfig[] configs = current.networkConfigs();
        if (configs == null || configs.length == 0) {
            shutdown();
        }
    }

    //
    // ZeroTier 事件与网络配置回调
    //

    @Override
    public void onEvent(Event event) {
        Log.d(TAG, "Event: " + event);
    }

    @Override
    public void onTrace(String trace) {
        Log.d(TAG, "Trace: " + trace);
    }

    @Override
    public int onNetworkConfigurationUpdated(long nwid, VirtualNetworkConfigOperation op,
                                             VirtualNetworkConfig config) {
        Log.i(TAG, "Virtual network config operation: " + op);
        switch (op) {
            case VIRTUAL_NETWORK_CONFIG_OPERATION_CONFIG_UPDATE: {
                VirtualNetworkConfig old = putVirtualNetworkConfig(nwid, config);
                boolean changed = !config.equals(old);
                if (changed && config.getStatus() == VirtualNetworkStatus.NETWORK_STATUS_OK) {
                    try {
                        updateTunnelConfig(config);
                    } catch (Exception e) {
                        Log.e(TAG, "updateTunnelConfig failed", e);
                        notifyFatal("VPN 配置失败: " + e.getMessage());
                    }
                }
                notifyNetworkStatus(config);
                break;
            }
            case VIRTUAL_NETWORK_CONFIG_OPERATION_DOWN:
            case VIRTUAL_NETWORK_CONFIG_OPERATION_DESTROY: {
                removeVirtualNetworkConfig(nwid);
                notifyNetworkStatus(nwid, config.getStatus(), null);
                break;
            }
            default:
                break;
        }
        return 0;
    }

    /**
     * 根据最新网络配置（重新）建立 TUN
     */
    private boolean updateTunnelConfig(VirtualNetworkConfig vnc) {
        long nwid = vnc.getNwid();

        // 停止旧 TUN 接收线程
        if (this.tunTapAdapter.isRunning()) {
            this.tunTapAdapter.interrupt();
            try {
                this.tunTapAdapter.join();
            } catch (InterruptedException ignored) {
            }
        }
        this.tunTapAdapter.clearRouteMap();

        // 关闭旧 VPN
        closeVpnSocket();

        Log.i(TAG, "Configuring VpnService.Builder");
        VpnService.Builder builder = new VpnService.Builder();
        InetSocketAddress[] assignedAddresses = vnc.getAssignedAddresses();

        // 遍历分配给本设备的地址：addAddress/addRoute + 组播订阅
        for (InetSocketAddress vpnAddress : assignedAddresses) {
            InetAddress address = vpnAddress.getAddress();
            int prefix = vpnAddress.getPort();
            InetAddress route = InetAddressUtils.addressToRoute(address, prefix);
            if (route == null) {
                Log.e(TAG, "NULL route calculated!");
                continue;
            }

            byte[] rawAddress = address.getAddress();
            long multicastGroup;
            long multicastAdi;
            if (rawAddress.length == 4) {
                // IPv4：广播 MAC + ADI（本机 IPv4 主机序），使 ARP 以可扩展组播方式工作
                multicastGroup = InetAddressUtils.BROADCAST_MAC_ADDRESS;
                multicastAdi = ByteBuffer.wrap(rawAddress).getInt();
            } else {
                // IPv6
                multicastGroup = ByteBuffer.wrap(new byte[]{
                        0, 0, 0x33, 0x33, (byte) 0xFF,
                        rawAddress[13], rawAddress[14], rawAddress[15]}).getLong();
                multicastAdi = 0;
            }
            ResultCode result = node.multicastSubscribe(nwid, multicastGroup, multicastAdi);
            if (result != ResultCode.RESULT_OK) {
                Log.e(TAG, "Error joining multicast group: " + result);
            }

            builder.addAddress(address, prefix);
            builder.addRoute(route, prefix);
            tunTapAdapter.addRouteAndNetwork(new Route(route, prefix), nwid);
        }

        // 网络下发的路由规则（默认路由除外，QuiX 不接管全部流量）
        try {
            InetAddress v4Default = InetAddress.getByName("0.0.0.0");
            InetAddress v6Default = InetAddress.getByName("::");
            for (VirtualNetworkRoute routeConfig : vnc.getRoutes()) {
                InetSocketAddress target = routeConfig.getTarget();
                InetSocketAddress via = routeConfig.getVia();
                InetAddress targetAddress = target.getAddress();
                int targetPrefix = target.getPort();
                InetAddress routeAddress = InetAddressUtils.addressToRoute(targetAddress, targetPrefix);
                if (routeAddress == null) {
                    continue;
                }
                if (routeAddress.equals(v4Default) || routeAddress.equals(v6Default)) {
                    // 不接管默认路由
                    continue;
                }
                builder.addRoute(routeAddress, targetPrefix);
                Route route = new Route(routeAddress, targetPrefix);
                if (via != null) {
                    route.setGateway(via.getAddress());
                }
                tunTapAdapter.addRouteAndNetwork(route, nwid);
            }
            builder.addRoute(InetAddress.getByName("224.0.0.0"), 4);
        } catch (Exception e) {
            notifyFatal("VPN 路由配置失败: " + e.getLocalizedMessage());
            return false;
        }

        if (Build.VERSION.SDK_INT >= 29) {
            builder.setMetered(false);
        }

        // DNS（网络控制器下发的配置）
        VirtualNetworkDNS dns = vnc.getDns();
        if (dns != null) {
            if (dns.getDomain() != null && !dns.getDomain().isEmpty()) {
                builder.addSearchDomain(dns.getDomain());
            }
            for (InetSocketAddress server : dns.getServers()) {
                try {
                    builder.addDnsServer(server.getAddress());
                } catch (Exception e) {
                    Log.e(TAG, "Cannot add DNS server", e);
                }
            }
        }

        // MTU
        int mtu = vnc.getMtu();
        Log.i(TAG, "MTU from network config: " + mtu);
        if (mtu == 0) {
            mtu = 2800;
        }
        builder.setMtu(mtu);
        builder.setSession(VPN_SESSION_NAME);

        // 指定应用不经过 VPN
        for (String app : DISALLOWED_APPS) {
            try {
                builder.addDisallowedApplication(app);
            } catch (Exception e) {
                Log.e(TAG, "Cannot disallow app", e);
            }
        }

        // 建立 VPN
        this.vpnSocket = builder.establish();
        if (this.vpnSocket == null) {
            notifyFatal("VPN 建立失败，请重新授权");
            return false;
        }
        this.in = new FileInputStream(this.vpnSocket.getFileDescriptor());
        this.out = new FileOutputStream(this.vpnSocket.getFileDescriptor());
        tunTapAdapter.setVpnSocket(this.vpnSocket);
        tunTapAdapter.setFileStreams(this.in, this.out);
        tunTapAdapter.startThreads();

        try {
            notificationManager.notify(NOTIFICATION_ID, buildNotification("ZeroTier 组网运行中"));
        } catch (Exception e) {
            Log.e(TAG, "notify failed", e);
        }
        Log.i(TAG, "ZeroTier tunnel up");
        return true;
    }

    private void closeVpnSocket() {
        if (vpnSocket != null) {
            try {
                vpnSocket.close();
                if (in != null) {
                    in.close();
                }
                if (out != null) {
                    out.close();
                }
            } catch (Exception e) {
                Log.e(TAG, "Error closing VPN socket: " + e, e);
            }
            vpnSocket = null;
            in = null;
            out = null;
        }
    }

    /**
     * 停止全部资源。可在任意线程调用
     */
    public void stopZeroTier() {
        if (udpThread != null) {
            if (udpThread.isAlive()) {
                udpThread.interrupt();
                try {
                    udpThread.join();
                } catch (InterruptedException ignored) {
                }
            }
            udpThread = null;
        }
        if (tunTapAdapter != null) {
            if (tunTapAdapter.isRunning()) {
                tunTapAdapter.interrupt();
                try {
                    tunTapAdapter.join();
                } catch (InterruptedException ignored) {
                }
            }
            tunTapAdapter = null;
        }
        if (vpnThread != null) {
            if (vpnThread.isAlive()) {
                vpnThread.interrupt();
                try {
                    vpnThread.join();
                } catch (InterruptedException ignored) {
                }
            }
            vpnThread = null;
        }
        closeVpnSocket();
        if (svrSocket != null) {
            try {
                svrSocket.close();
            } catch (Exception e) {
                Log.e(TAG, "Error closing UDP socket", e);
            }
            svrSocket = null;
        }
        if (node != null) {
            node.close();
            node = null;
        }
        synchronized (virtualNetworkConfigMap) {
            virtualNetworkConfigMap.clear();
        }
        if (notificationManager != null) {
            notificationManager.cancel(NOTIFICATION_ID);
        }
        if (mStartID >= 0 && !stopSelfResult(mStartID)) {
            Log.d(TAG, "stopSelfResult returned false");
        }
    }

    /**
     * 致命错误时由内部线程调用
     */
    void shutdown() {
        stopZeroTier();
        stopSelf(mStartID);
    }

    @Override
    public void onDestroy() {
        try {
            stopZeroTier();
        } catch (Exception e) {
            Log.e(TAG, e.toString(), e);
        } finally {
            super.onDestroy();
        }
    }

    @Override
    public void onRevoke() {
        stopZeroTier();
        stopSelf(mStartID);
        super.onRevoke();
    }

    //
    // 状态回调分发（统一切换到主线程）
    //

    private void notifyNodeUp(long nodeAddress) {
        mainHandler.post(() -> {
            IZeroTierCallback listener = statusListener;
            if (listener != null) {
                try {
                    listener.onNodeUp(nodeAddress);
                } catch (Exception e) {
                    Log.e(TAG, "notifyNodeUp callback failed", e);
                }
            }
        });
    }

    private void notifyNetworkStatus(VirtualNetworkConfig config) {
        notifyNetworkStatus(config.getNwid(), config.getStatus(), firstIpv4(config));
    }

    private void notifyNetworkStatus(long nwid, VirtualNetworkStatus status, String ip) {
        final int statusCode = statusToInt(status);
        mainHandler.post(() -> {
            IZeroTierCallback listener = statusListener;
            if (listener != null) {
                try {
                    listener.onNetworkStatus(nwid, statusCode, ip);
                } catch (Exception e) {
                    Log.e(TAG, "notifyNetworkStatus callback failed", e);
                }
            }
        });
    }

    private void notifyFatal(String message) {
        mainHandler.post(() -> {
            IZeroTierCallback listener = statusListener;
            if (listener != null) {
                try {
                    listener.onFatalError(message);
                } catch (Exception e) {
                    Log.e(TAG, "notifyFatal callback failed", e);
                }
            }
        });
    }

    /**
     * 将 SDK 枚举转为 AIDL 传输用的 int（与 ZeroTierOne.h 中 ZT_VirtualNetworkStatus 一致）
     */
    private static int statusToInt(VirtualNetworkStatus status) {
        if (status == null) {
            return -1;
        }
        switch (status) {
            case NETWORK_STATUS_REQUESTING_CONFIGURATION: return 0;
            case NETWORK_STATUS_OK:                       return 1;
            case NETWORK_STATUS_ACCESS_DENIED:            return 2;
            case NETWORK_STATUS_NOT_FOUND:                return 3;
            case NETWORK_STATUS_PORT_ERROR:               return 4;
            case NETWORK_STATUS_CLIENT_TOO_OLD:           return 5;
            case NETWORK_STATUS_AUTHENTICATION_REQUIRED:  return 6;
            default:                                      return -1;
        }
    }

    private static String firstIpv4(VirtualNetworkConfig config) {
        for (InetSocketAddress address : config.getAssignedAddresses()) {
            if (address.getAddress() instanceof Inet4Address) {
                return address.getAddress().getHostAddress();
            }
        }
        return null;
    }
}
