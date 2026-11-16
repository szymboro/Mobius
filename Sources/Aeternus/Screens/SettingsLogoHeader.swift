import SwiftUI
import UIKit

/// Lets a file that is kept out of the repository decorate the Settings logo. It is found at
/// runtime by its Objective-C class name, so the app builds the same with or without it.
protocol SettingsLogoExtra: AnyObject {
    @MainActor static func decorate(_ logo: AnyView) -> AnyView
}

/// Aeternus logo, name and version at the top of Settings.
struct SettingsLogoHeader: View {
    let version: String

    private static let extra = NSClassFromString("AeternusSettingsLogoExtra") as? SettingsLogoExtra.Type

    var body: some View {
        VStack(spacing: 8) {
            if let extra = Self.extra {
                extra.decorate(AnyView(logo))
            } else {
                logo
            }
            Text("Aeternus")
                .font(.title2.weight(.bold))
            Text(version)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    private var logo: some View {
        logoImage
            .resizable()
            .scaledToFit()
            .frame(width: 88, height: 88)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
            .accessibilityLabel("Aeternus")
    }

    private var logoImage: Image {
        if let image = UIImage(named: "AppIcon60x60@3x") ?? UIImage(named: "AppIcon60x60") {
            return Image(uiImage: image)
        }
        return Image(systemName: "play.rectangle.fill")
    }
}
