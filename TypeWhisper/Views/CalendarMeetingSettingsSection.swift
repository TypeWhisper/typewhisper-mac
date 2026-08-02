import SwiftUI

struct CalendarMeetingFreePreviewSection: View {
    let onUpgrade: () -> Void

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "calendar.badge.clock")
                        .font(.title2)
                        .foregroundStyle(.blue)
                        .frame(width: 42, height: 42)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(.blue.opacity(0.12))
                        )

                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(localized: "calendarMeeting.settings.title"))
                            .font(.headline)
                        Text(String(localized: "calendarMeeting.preview.description"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Label(String(localized: "Premium"), systemImage: "lock.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(localized: "calendarMeeting.preview.exampleTitle"))
                            .font(.callout.weight(.semibold))
                        Text(String(localized: "calendarMeeting.preview.exampleTime"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Label("Zoom", systemImage: "video.fill")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(.blue.opacity(0.11)))
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.secondary.opacity(0.06))
                )

                HStack {
                    Text(String(localized: "calendarMeeting.preview.privacy"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(String(localized: "calendarMeeting.preview.upgrade"), action: onUpgrade)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("calendarMeeting.preview.upgrade")
                }
            }
        }
    }
}

@MainActor
struct CalendarMeetingSettingsSection: View {
    @ObservedObject var controller: CalendarMeetingAutomationController

    var body: some View {
        PremiumControlSection(
            icon: "calendar.badge.clock",
            iconColor: .blue,
            title: String(localized: "calendarMeeting.settings.title"),
            description: String(localized: "calendarMeeting.settings.description"),
            statusText: statusText,
            statusColor: controller.isAutomationActive ? .green : .secondary
        ) {
            VStack(alignment: .leading, spacing: 14) {
                Picker(
                    String(localized: "calendarMeeting.settings.startMode"),
                    selection: startModeBinding
                ) {
                    Text(String(localized: "calendarMeeting.mode.off"))
                        .tag(CalendarMeetingStartMode.off)
                    Text(String(localized: "calendarMeeting.mode.reminder"))
                        .tag(CalendarMeetingStartMode.reminder)
                    Text(String(localized: "calendarMeeting.mode.automatic"))
                        .tag(CalendarMeetingStartMode.automatic)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("calendarMeeting.startMode")

                if controller.startMode != .off {
                    Divider()
                    permissionStatus

                    if controller.calendarAuthorization == .fullAccess {
                        calendarSelection
                        providerSelection

                        Toggle(
                            String(localized: "calendarMeeting.settings.autoStop"),
                            isOn: Binding(
                                get: { controller.autoStopEnabled },
                                set: { isEnabled in
                                    controller.setAutoStopEnabled(isEnabled)
                                }
                            )
                        )
                        .toggleStyle(.switch)
                        .accessibilityIdentifier("calendarMeeting.autoStop")

                        Text(String(localized: "calendarMeeting.settings.autoStopHelp"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Label(
                    String(localized: "calendarMeeting.settings.privacy"),
                    systemImage: "hand.raised.fill"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .alert(
            String(localized: "calendarMeeting.permission.title"),
            isPresented: $controller.permissionExplanationPresented
        ) {
            Button(String(localized: "calendarMeeting.permission.continue")) {
                controller.confirmPermissionExplanation()
            }
            .accessibilityIdentifier("calendarMeeting.permission.continue")
            Button(String(localized: "Cancel"), role: .cancel) {
                controller.cancelPermissionExplanation()
            }
        } message: {
            Text(String(localized: "calendarMeeting.permission.message"))
        }
    }

    private var startModeBinding: Binding<CalendarMeetingStartMode> {
        Binding(
            get: { controller.startMode },
            set: { startMode in
                controller.setStartMode(startMode)
            }
        )
    }

    @ViewBuilder
    private var permissionStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(
                    calendarStatusText,
                    systemImage: controller.calendarAuthorization == .fullAccess
                        ? "checkmark.circle.fill"
                        : "exclamationmark.triangle.fill"
                )
                .foregroundStyle(
                    controller.calendarAuthorization == .fullAccess ? .green : .orange
                )
                Spacer()
                if controller.calendarAuthorization != .fullAccess {
                    Button(String(localized: "calendarMeeting.settings.openCalendarSettings")) {
                        controller.openCalendarPrivacySettings()
                    }
                    .accessibilityIdentifier("calendarMeeting.permission.calendarSettings")
                }
            }

            HStack {
                Label(notificationStatusText, systemImage: "bell")
                    .foregroundStyle(.secondary)
                Spacer()
                if controller.notificationAuthorization == .denied {
                    Button(String(localized: "calendarMeeting.settings.openNotificationSettings")) {
                        controller.openNotificationSettings()
                    }
                    .accessibilityIdentifier("calendarMeeting.permission.notificationSettings")
                }
            }
            Text(String(localized: "calendarMeeting.settings.notificationHelp"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var calendarSelection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "calendarMeeting.settings.calendars"))
                .font(.callout.weight(.semibold))

            if controller.calendars.isEmpty {
                Text(String(localized: "calendarMeeting.settings.noCalendars"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(controller.calendars.enumerated()), id: \.element.id) { index, calendar in
                    Toggle(isOn: Binding(
                        get: { controller.selectedCalendarIDs.contains(calendar.id) },
                        set: { controller.setCalendar(calendar.id, enabled: $0) }
                    )) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(calendar.title)
                            Text(calendar.sourceTitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("calendarMeeting.calendar.\(index)")
                }
            }
        }
    }

    private var providerSelection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "calendarMeeting.settings.providers"))
                .font(.callout.weight(.semibold))
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading) {
                ForEach(MeetingProvider.allCases) { provider in
                    Toggle(
                        provider.displayName,
                        isOn: Binding(
                            get: { controller.enabledProviders.contains(provider) },
                            set: { controller.setProvider(provider, enabled: $0) }
                        )
                    )
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("calendarMeeting.provider.\(provider.rawValue)")
                }
            }
        }
    }

    private var statusText: String {
        if controller.startMode == .off {
            return String(localized: "calendarMeeting.status.off")
        }
        if controller.calendarAuthorization != .fullAccess {
            return String(localized: "calendarMeeting.status.permissionRequired")
        }
        return controller.startMode == .automatic
            ? String(localized: "calendarMeeting.status.automatic")
            : String(localized: "calendarMeeting.status.reminder")
    }

    private var calendarStatusText: String {
        switch controller.calendarAuthorization {
        case .fullAccess:
            String(localized: "calendarMeeting.permission.calendarGranted")
        case .notDetermined:
            String(localized: "calendarMeeting.permission.calendarNotDetermined")
        case .denied, .restricted, .writeOnly, .unknown:
            String(localized: "calendarMeeting.permission.calendarDenied")
        }
    }

    private var notificationStatusText: String {
        switch controller.notificationAuthorization {
        case .authorized, .provisional, .ephemeral:
            String(localized: "calendarMeeting.permission.notificationsGranted")
        case .notDetermined:
            String(localized: "calendarMeeting.permission.notificationsNotDetermined")
        case .denied, .unknown:
            String(localized: "calendarMeeting.permission.notificationsDenied")
        }
    }
}
