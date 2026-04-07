import SwiftUI

struct LicenseSettingsView: View {
    @ObservedObject private var license = LicenseService.shared

    @State private var licenseKeyInput = ""

    var body: some View {
        Form {
            Section(String(localized: "License Status")) {
                statusView
            }

            if license.licenseStatus != .active {
                Section(String(localized: "Activate with License Key")) {
                    Text(String(localized: "If you need a commercial license for proprietary or otherwise non-GPL-compliant use, purchase it on Polar.sh and enter the key below."))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        TextField(String(localized: "TYPEWHISPER-xxxx-xxxx"), text: $licenseKeyInput)
                            .textFieldStyle(.roundedBorder)

                        Button(String(localized: "Activate")) {
                            Task {
                                await license.activateLicenseKey(licenseKeyInput.trimmingCharacters(in: .whitespacesAndNewlines))
                            }
                        }
                        .disabled(licenseKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || license.isActivating)
                    }

                    if license.isActivating {
                        ProgressView()
                            .controlSize(.small)
                    }

                    if let error = license.activationError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }

                Section(String(localized: "Purchase")) {
                    HStack(spacing: 16) {
                        tierButton(tier: .individual, price: "5", url: AppConstants.Polar.checkoutURLIndividual)
                        tierButton(tier: .team, price: "19", url: AppConstants.Polar.checkoutURLTeam)
                        tierButton(tier: .enterprise, price: "99", url: AppConstants.Polar.checkoutURLEnterprise)
                    }
                    .padding(.vertical, 4)

                    Text(String(localized: "Pay-what-you-want starting at the listed price. Click a tier to open the checkout page."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            }

            if license.licenseStatus == .active {
                Section(String(localized: "Manage")) {
                    Button(String(localized: "Deactivate License on This Mac"), role: .destructive) {
                        Task { await license.deactivateLicense() }
                    }

                    Text(String(localized: "Removes the license from this device. You can reactivate it on another Mac."))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let error = license.deactivationError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
            }

            Section(String(localized: "User Type")) {
                Picker(String(localized: "I use TypeWhisper"), selection: Binding(
                    get: { license.userType ?? .privateUser },
                    set: { license.setUserType($0) }
                )) {
                    Text(String(localized: "Personal / OSS")).tag(LicenseUserType.privateUser)
                    Text(String(localized: "Proprietary")).tag(LicenseUserType.business)
                }
                .pickerStyle(.segmented)

                Text(String(localized: "Personal use and GPL-compliant open-source use are free. Proprietary or otherwise non-GPL-compliant use requires a commercial license."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 500, minHeight: 300)
    }

    @ViewBuilder
    private var statusView: some View {
        switch license.licenseStatus {
        case .active:
            HStack {
                Label(String(localized: "Licensed"), systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                if let tier = license.licenseTier {
                    Text("(\(tierDisplayName(tier)))")
                        .foregroundStyle(.secondary)
                }
            }
        case .expired:
            Label(String(localized: "License expired or revoked"), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .unlicensed:
            if license.userType == .business {
                Label(String(localized: "No active commercial license"), systemImage: "key")
                    .foregroundStyle(.secondary)
            } else {
                Label(String(localized: "Free for personal and GPL-compliant open-source use"), systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            }
        }
    }

    private func tierButton(tier: LicenseTier, price: String, url: String) -> some View {
        Button {
            if let checkoutURL = URL(string: url) {
                NSWorkspace.shared.open(checkoutURL)
            }
        } label: {
            VStack(spacing: 4) {
                Text(tierDisplayName(tier))
                    .font(.caption.bold())
                Text(String(localized: "from \(price) EUR/mo"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .buttonStyle(.bordered)
    }

    private func tierDisplayName(_ tier: LicenseTier) -> String {
        switch tier {
        case .individual: return "Individual Business"
        case .team: return "Team"
        case .enterprise: return "Enterprise"
        }
    }
}
