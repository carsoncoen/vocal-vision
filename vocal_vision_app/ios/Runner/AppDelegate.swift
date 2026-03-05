import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
      
      let controller = window?.rootViewController as! FlutterViewController
      let lidarChannel = FlutterEventChannel(name: "com.vocalvision.app/lidar_stream",
                                         binaryMessenger: controller.binaryMessenger)
      let depthStreamHandler = DepthStreamHandler()
      lidarChannel.setStreamHandler(depthStreamHandler)
    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
