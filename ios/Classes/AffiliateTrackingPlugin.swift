import Flutter
import UIKit

public class AffiliateTrackingPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "affiliate_tracking", binaryMessenger: registrar.messenger())
    let instance = AffiliateTrackingPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getPlatformInfo":
      result([
        "osVersion": UIDevice.current.systemVersion,
        "model": UIDevice.current.model
      ])
    case "getInstallReferrer":
      // iOS does not have an install referrer mechanism like Google Play.
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
