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
        .custom(SidarTypeface.regular, size: size, relativeTo: textStyle)
    }

    static func medium(_ size: CGFloat, relativeTo textStyle: Font.TextStyle = .body) -> Font {
        .custom(SidarTypeface.medium, size: size, relativeTo: textStyle)
    }

    static func demi(_ size: CGFloat, relativeTo textStyle: Font.TextStyle = .body) -> Font {
        .custom(SidarTypeface.demiBold, size: size, relativeTo: textStyle)
    }

    static func heavy(_ size: CGFloat, relativeTo textStyle: Font.TextStyle = .body) -> Font {
        .custom(SidarTypeface.heavy, size: size, relativeTo: textStyle)
    }

    static let body = regular(17)
    static let caption = medium(12, relativeTo: .caption)
    static let footnote = medium(13, relativeTo: .footnote)
}

@main
struct PhoneSceneCaptureApp: App {
    @StateObject private var recorder = ARRecorder()

    init() {
        let titleFont = UIFont(name: SidarTypeface.regular, size: 17) ?? .systemFont(ofSize: 17, weight: .regular)
        let largeTitleFont = UIFont(name: SidarTypeface.regular, size: 34) ?? .systemFont(ofSize: 34, weight: .regular)
        UINavigationBar.appearance().titleTextAttributes = [.font: titleFont]
        UINavigationBar.appearance().largeTitleTextAttributes = [.font: largeTitleFont]
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(recorder)
        }
    }
}
