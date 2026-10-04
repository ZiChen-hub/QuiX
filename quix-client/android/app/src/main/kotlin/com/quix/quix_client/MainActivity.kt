package com.quix.quix_client

import android.content.Intent
import com.quix.quix_client.zerotier.ZerotierVpnBridge
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val channelName = "quix/native"
    private var zerotierVpnBridge: ZerotierVpnBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isAppInstalled" -> {
                        val pkg = call.argument<String>("pkg").orEmpty()
                        result.success(isAppInstalled(pkg))
                    }
                    "launchApp" -> {
                        val pkg = call.argument<String>("pkg").orEmpty()
                        result.success(launchApp(pkg))
                    }
                    else -> result.notImplemented()
                }
            }
        // 内嵌 ZeroTier VPN 桥接
        zerotierVpnBridge = ZerotierVpnBridge(this, flutterEngine.dartExecutor.binaryMessenger)
    }

    @Deprecated("Deprecated in Java; required for VPN consent forwarding")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        zerotierVpnBridge?.handleActivityResult(requestCode, resultCode)
        super.onActivityResult(requestCode, resultCode, data)
    }

    // 检测指定包名的应用是否已安装
    private fun isAppInstalled(pkg: String): Boolean {
        if (pkg.isEmpty()) return false
        return try {
            packageManager.getPackageInfo(pkg, 0)
            true
        } catch (e: Exception) {
            false
        }
    }

    // 启动指定包名的应用，返回是否成功
    private fun launchApp(pkg: String): Boolean {
        val intent = packageManager.getLaunchIntentForPackage(pkg) ?: return false
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        startActivity(intent)
        return true
    }
}
