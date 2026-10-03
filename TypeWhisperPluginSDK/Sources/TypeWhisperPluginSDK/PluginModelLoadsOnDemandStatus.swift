import SwiftUI

/// Shown in place of a Load button for the model the host loads on demand,
/// see `HostServices.modelIdLoadedOnDemand`.
public struct PluginModelLoadsOnDemandStatus: View {
    private let bundle: Bundle

    public init(bundle: Bundle) {
        self.bundle = bundle
    }

    public var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Label(String(localized: "Loads on demand", bundle: bundle), systemImage: "checkmark.circle")
                .font(.callout)
            Text(String(localized: "Auto-unload model is set to Immediate.", bundle: bundle))
                .font(.caption2)
        }
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.trailing)
        .accessibilityElement(children: .combine)
    }
}
