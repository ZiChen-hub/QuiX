package com.quix.quix_client.zerotier

import android.app.Activity
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import com.quix.zerotier.IZeroTierCallback
import com.quix.zerotier.IZeroTierService
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors

/**
 * Dart 与内嵌 ZeroTier VPN 服务之间的桥接。
 *
 * 通道：quix/zerotier_vpn
 * 方法：
 *  - joinAndWaitIp({networkId: 16位十六进制})：VPN 授权 → 启动/绑定服务 → join → 返回分配的 IPv4
 *  - stop()：停止 VPN 服务并解绑
 *  - isRunning()：服务是否已绑定运行
 *
 * 注意：本文件不直接 import 任何 GPL 代码，通过 AIDL 与 :zerotier 进程通信。
 */
class ZerotierVpnBridge(
    private val activity: Activity,
    messenger: BinaryMessenger
) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL_NAME = "quix/zerotier_vpn"
        private const val VPN_REQUEST_CODE = 0xA71E // 42782

        // AIDL 网络状态码（与 ZeroTierOne.h 中 ZT_VirtualNetworkStatus 一致）
        private const val STATUS_OK = 1
    }

    private sealed class ZtEvent {
        data class IpAssigned(val ip: String) : ZtEvent()
        data class Fatal(val message: String) : ZtEvent()
    }

    private val channel = MethodChannel(messenger, CHANNEL_NAME)
    private val worker = Executors.newSingleThreadExecutor { r -> Thread(r, "zt-vpn-bridge") }
    private val mainHandler = Handler(Looper.getMainLooper())
    private val eventQueue = ArrayBlockingQueue<ZtEvent>(8)

    @Volatile
    private var service: IZeroTierService? = null
    private var bound = false

    private var consentLatch: CountDownLatch? = null
    @Volatile
    private var consentGranted = false
    private var bindLatch: CountDownLatch? = null

    private val aidlCallback = object : IZeroTierCallback.Stub() {
        override fun onNodeUp(nodeAddress: Long) {
            // 当前业务不需要
        }

        override fun onNetworkStatus(networkId: Long, status: Int, assignedIp: String?) {
            if (status == STATUS_OK && !assignedIp.isNullOrEmpty()) {
                eventQueue.offer(ZtEvent.IpAssigned(assignedIp))
            }
        }

        override fun onFatalError(message: String?) {
            eventQueue.offer(ZtEvent.Fatal(message ?: "ZeroTier 服务发生错误"))
        }
    }

    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
            val s = IZeroTierService.Stub.asInterface(binder) ?: return
            service = s
            try {
                s.setCallback(aidlCallback)
            } catch (e: Exception) {
                // 服务已死亡或 IPC 失败
            }
            bindLatch?.countDown()
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            service = null
            eventQueue.offer(ZtEvent.Fatal("VPN 服务已断开"))
        }
    }

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "joinAndWaitIp" -> {
                val nwid = parseNetworkId(call.argument<String>("networkId"))
                if (nwid == null) {
                    result.error("BAD_NWID", "网络 ID 无效（应为 16 位十六进制）", null)
                    return
                }
                worker.execute { doJoinAndWaitIp(nwid, result) }
            }
            "stop" -> worker.execute { doStop(result) }
            "isRunning" -> result.success(service != null)
            else -> result.notImplemented()
        }
    }

    private fun doJoinAndWaitIp(nwid: Long, result: MethodChannel.Result) {
        try {
            eventQueue.clear()
            // 1. VPN 授权
            ensureVpnConsent()
            // 2. 启动并绑定服务（通过显式 Intent 指定 :zerotier 进程中的组件）
            val intent = Intent().apply {
                component = ComponentName(
                    activity.packageName,
                    "com.quix.zerotier.ZeroTierOneService"
                )
                putExtra("com.quix.zerotier.network_id", nwid)
            }
            startService(intent)
            ensureBound(intent)
            // 3. join（onStartCommand 已 join，此处幂等保证）
            service?.joinNetwork(nwid)
            // 4. 等待分配 IP（整体超时由 Dart 侧控制）
            while (true) {
                when (val event = eventQueue.take()) {
                    is ZtEvent.IpAssigned -> {
                        result.success(event.ip)
                        return
                    }
                    is ZtEvent.Fatal -> {
                        result.error("ZT_FATAL", event.message, null)
                        return
                    }
                }
            }
        } catch (e: InterruptedException) {
            result.error("ZT_INTERRUPTED", e.message ?: "操作被中断", null)
        } catch (e: Exception) {
            result.error("ZT_ERROR", e.message ?: e.toString(), null)
        }
    }

    private fun doStop(result: MethodChannel.Result) {
        val s = service
        val wasBound = bound
        service = null
        bound = false
        eventQueue.clear()
        mainHandler.post {
            try {
                s?.stopZeroTier()
            } catch (e: Exception) {
                // 忽略，继续解绑/停止
            }
            try {
                if (wasBound) {
                    activity.unbindService(connection)
                }
            } catch (e: Exception) {
                // 未绑定等异常忽略
            }
            try {
                activity.stopService(Intent().apply {
                    component = ComponentName(
                        activity.packageName,
                        "com.quix.zerotier.ZeroTierOneService"
                    )
                })
            } catch (e: Exception) {
                // 忽略
            }
        }
        result.success(null)
    }

    /**
     * 确保已获得系统 VPN 授权；未授权时弹出系统授权框并等待用户选择
     */
    private fun ensureVpnConsent() {
        val prepareLatch = CountDownLatch(1)
        var prepareIntent: Intent? = null
        mainHandler.post {
            try {
                prepareIntent = VpnService.prepare(activity)
            } finally {
                prepareLatch.countDown()
            }
        }
        prepareLatch.await()
        val intent = prepareIntent ?: return // null 表示已授权

        val latch = CountDownLatch(1)
        consentLatch = latch
        consentGranted = false
        mainHandler.post {
            activity.startActivityForResult(intent, VPN_REQUEST_CODE)
        }
        latch.await()
        consentLatch = null
        if (!consentGranted) {
            throw IllegalStateException("用户拒绝了 VPN 授权")
        }
    }

    private fun startService(intent: Intent) {
        mainHandler.post {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                activity.startForegroundService(intent)
            } else {
                activity.startService(intent)
            }
        }
    }

    private fun ensureBound(intent: Intent) {
        if (service != null) return
        val latch = CountDownLatch(1)
        bindLatch = latch
        mainHandler.post {
            bound = activity.bindService(intent, connection, Context.BIND_AUTO_CREATE)
        }
        latch.await()
        bindLatch = null
    }

    /**
     * 由 MainActivity.onActivityResult 转发
     */
    fun handleActivityResult(requestCode: Int, resultCode: Int) {
        if (requestCode == VPN_REQUEST_CODE) {
            consentGranted = resultCode == Activity.RESULT_OK
            consentLatch?.countDown()
        }
    }

    private fun parseNetworkId(value: String?): Long? {
        if (value == null) return null
        val trimmed = value.trim().lowercase()
        if (!trimmed.matches(Regex("[0-9a-f]{16}"))) return null
        // toULong 处理最高位为 1 的无符号 64 位网络 ID
        return trimmed.toULong(16).toLong()
    }
}
