import SwiftUI
import UIKit

enum SidarTypeface {
    static let regular = "TimesNewRomanPSMT"
    static let medium = "TimesNewRomanPSMT"
    static let demiBold = "TimesNewRomanPSMT"
    static let heavy = "TimesNewRomanPSMT"
}

enum SidarFont {
    static func regular(_ size: CGFloat, relativeTo textStyle: Font.TextStyle = .body) -> Font {
        .system(size: size, weight: .regular)
    }

    static func medium(_ size: CGFloat, relativeTo textStyle: Font.TextStyle = .body) -> Font {
        .system(size: size, weight: .medium)
    }

    static func demi(_ size: CGFloat, relativeTo textStyle: Font.TextStyle = .body) -> Font {
        .system(size: size, weight: .semibold)
    }

    static func heavy(_ size: CGFloat, relativeTo textStyle: Font.TextStyle = .body) -> Font {
        .system(size: size, weight: .bold)
    }

    static let body = regular(17)
    static let caption = medium(12, relativeTo: .caption)
    static let footnote = medium(13, relativeTo: .footnote)
}

enum SidarTheme {
    static let jadeBackground = Color(red: 0.958, green: 0.982, blue: 0.968)
    static let jadeBackgroundDeep = Color(red: 0.894, green: 0.946, blue: 0.918)
    static let jadeSurface = Color(red: 0.988, green: 0.997, blue: 0.991)
    static let jadeSurfaceQuiet = Color(red: 0.934, green: 0.970, blue: 0.948)
    static let jadeLine = Color(red: 0.694, green: 0.824, blue: 0.762)
    static let jadeInk = Color(red: 0.088, green: 0.150, blue: 0.132)
    static let jadeMuted = Color(red: 0.314, green: 0.426, blue: 0.388)
    static let jadeAccent = Color(red: 0.070, green: 0.500, blue: 0.415)

    static let jadeBackgroundUIColor = UIColor(red: 0.958, green: 0.982, blue: 0.968, alpha: 1)
    static let jadeSurfaceUIColor = UIColor(red: 0.988, green: 0.997, blue: 0.991, alpha: 1)
    static let jadeLineUIColor = UIColor(red: 0.694, green: 0.824, blue: 0.762, alpha: 1)
    static let jadeInkUIColor = UIColor(red: 0.088, green: 0.150, blue: 0.132, alpha: 1)
    static let jadeAccentUIColor = UIColor(red: 0.070, green: 0.500, blue: 0.415, alpha: 1)
}

final class SidarAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        SidarOrientationLock.allowedOrientations
    }
}

enum SidarOrientationLock {
    static var allowedOrientations: UIInterfaceOrientationMask = .portrait

    static func set(_ mask: UIInterfaceOrientationMask) {
        if Thread.isMainThread {
            apply(mask)
        } else {
            DispatchQueue.main.async {
                apply(mask)
            }
        }
    }

    private static func apply(_ mask: UIInterfaceOrientationMask) {
        allowedOrientations = mask

        let windowScenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in windowScenes {
            for window in scene.windows {
                window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
                NSLog("SIDAR orientation update failed: \(error.localizedDescription)")
            }
        }
    }
}

@main
struct PhoneSceneCaptureApp: App {
    @UIApplicationDelegateAdaptor(SidarAppDelegate.self) private var appDelegate
    @StateObject private var recorder = ARRecorder()

    init() {
        let titleFont = UIFont.systemFont(ofSize: 17, weight: .semibold)
        let largeTitleFont = UIFont.systemFont(ofSize: 34, weight: .bold)

        let navAppearance = UINavigationBarAppearance()
        navAppearance.configureWithOpaqueBackground()
        navAppearance.backgroundColor = SidarTheme.jadeSurfaceUIColor
        navAppearance.shadowColor = SidarTheme.jadeLineUIColor
        navAppearance.titleTextAttributes = [
            .font: titleFont,
            .foregroundColor: SidarTheme.jadeInkUIColor
        ]
        navAppearance.largeTitleTextAttributes = [
            .font: largeTitleFont,
            .foregroundColor: SidarTheme.jadeInkUIColor
        ]

        UINavigationBar.appearance().standardAppearance = navAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navAppearance
        UINavigationBar.appearance().compactAppearance = navAppearance
        UINavigationBar.appearance().tintColor = SidarTheme.jadeAccentUIColor

        UITableView.appearance().backgroundColor = SidarTheme.jadeBackgroundUIColor
        UIScrollView.appearance().backgroundColor = SidarTheme.jadeBackgroundUIColor
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(recorder)
                .preferredColorScheme(.light)
                .tint(SidarTheme.jadeAccent)
        }
    }
}
