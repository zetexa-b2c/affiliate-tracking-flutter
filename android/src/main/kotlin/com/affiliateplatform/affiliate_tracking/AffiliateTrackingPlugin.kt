package com.affiliateplatform.affiliate_tracking

import android.content.Context
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import com.android.installreferrer.api.InstallReferrerClient
import com.android.installreferrer.api.InstallReferrerClient.InstallReferrerResponse
import com.android.installreferrer.api.InstallReferrerStateListener
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Native half of the affiliate_tracking SDK. Android only: reads the Google
 * Play Install Referrer so installs from affiliate Play Store links can be
 * attributed, and reports the OS version for the User-Agent.
 */
class AffiliateTrackingPlugin : FlutterPlugin, MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var context: Context
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "affiliate_tracking")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "getInstallReferrer" -> getInstallReferrer(result)
            "getPlatformInfo" -> result.success(mapOf("osVersion" to Build.VERSION.RELEASE))
            else -> result.notImplemented()
        }
    }

    private fun getInstallReferrer(result: Result) {
        val client = InstallReferrerClient.newBuilder(context).build()
        // The listener can fire setup-finished and then disconnected; a
        // MethodChannel result may only be answered once.
        val answered = AtomicBoolean(false)

        fun reply(block: () -> Unit) {
            if (!answered.compareAndSet(false, true)) return
            mainHandler.post {
                block()
                try {
                    client.endConnection()
                } catch (_: Exception) {
                    // Already closed.
                }
            }
        }

        try {
            client.startConnection(object : InstallReferrerStateListener {
                override fun onInstallReferrerSetupFinished(responseCode: Int) {
                    if (responseCode != InstallReferrerResponse.OK) {
                        reply { result.error(responseName(responseCode), null, null) }
                        return
                    }
                    try {
                        val details = client.installReferrer
                        val pkg = packageInfo()
                        val firstInstall = pkg?.firstInstallTime ?: 0L
                        val payload = mapOf(
                            "referrer" to details.installReferrer,
                            "clickTimestampSeconds" to details.referrerClickTimestampSeconds,
                            "installBeginTimestampSeconds" to details.installBeginTimestampSeconds,
                            "firstInstallTimeMillis" to firstInstall,
                            "lastUpdateTimeMillis" to (pkg?.lastUpdateTime ?: 0L),
                            // Same value on every read for this install, including
                            // after the user clears app data, and a new one after
                            // a reinstall. Dart uses it as the click id and in
                            // the app_install order id, so both stay idempotent.
                            "installKey" to UUID.nameUUIDFromBytes(
                                listOf(
                                    details.installReferrer,
                                    details.installBeginTimestampSeconds,
                                    details.referrerClickTimestampSeconds,
                                    firstInstall,
                                ).joinToString("|").toByteArray(Charsets.UTF_8)
                            ).toString(),
                        )
                        reply { result.success(payload) }
                    } catch (e: Exception) {
                        reply { result.error("REMOTE_EXCEPTION", e.message, null) }
                    }
                }

                override fun onInstallReferrerServiceDisconnected() {
                    reply { result.error("SERVICE_DISCONNECTED", null, null) }
                }
            })
        } catch (e: Exception) {
            // startConnection throws SecurityException on some devices without Play.
            reply { result.error("FEATURE_NOT_SUPPORTED", e.message, null) }
        }
    }

    private fun packageInfo(): PackageInfo? = try {
        val pm = context.packageManager
        if (Build.VERSION.SDK_INT >= 33) {
            pm.getPackageInfo(context.packageName, PackageManager.PackageInfoFlags.of(0))
        } else {
            @Suppress("DEPRECATION")
            pm.getPackageInfo(context.packageName, 0)
        }
    } catch (_: Exception) {
        null
    }

    private fun responseName(code: Int): String = when (code) {
        InstallReferrerResponse.FEATURE_NOT_SUPPORTED -> "FEATURE_NOT_SUPPORTED"
        InstallReferrerResponse.SERVICE_UNAVAILABLE -> "SERVICE_UNAVAILABLE"
        InstallReferrerResponse.DEVELOPER_ERROR -> "DEVELOPER_ERROR"
        InstallReferrerResponse.SERVICE_DISCONNECTED -> "SERVICE_DISCONNECTED"
        InstallReferrerResponse.PERMISSION_ERROR -> "PERMISSION_ERROR"
        else -> "UNKNOWN_$code"
    }
}
