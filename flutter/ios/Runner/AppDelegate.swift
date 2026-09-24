import UIKit
import Flutter

@main
@objc class AppDelegate: FlutterAppDelegate {
  // NelDesk: background task that keeps the connection alive for the ~30 s
  // iOS grants after leaving the app, so a quick app switch does not drop it.
  private var nelBackgroundTask: UIBackgroundTaskIdentifier = .invalid

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    dummyMethodToEnforceBundling();
    // Notifications work with both the AppDelegate and the UIScene lifecycles.
    NotificationCenter.default.addObserver(
      self, selector: #selector(nelDidEnterBackground),
      name: UIApplication.didEnterBackgroundNotification, object: nil)
    NotificationCenter.default.addObserver(
      self, selector: #selector(nelWillEnterForeground),
      name: UIApplication.willEnterForegroundNotification, object: nil)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  @objc private func nelDidEnterBackground() {
    nelEndBackgroundTask()
    nelBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "NelDeskKeepAlive") {
      [weak self] in self?.nelEndBackgroundTask()
    }
  }

  @objc private func nelWillEnterForeground() {
    nelEndBackgroundTask()
  }

  private func nelEndBackgroundTask() {
    if nelBackgroundTask != .invalid {
      UIApplication.shared.endBackgroundTask(nelBackgroundTask)
      nelBackgroundTask = .invalid
    }
  }

  public func dummyMethodToEnforceBundling() {
      dummy_method_to_enforce_bundling();
    session_get_rgba(nil, 0);
  }
}
