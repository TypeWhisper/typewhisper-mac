import SwiftUI

@MainActor
struct CalendarMeetingSettingsSection: View {
    @ObservedObject var controller: CalendarMeetingAutomationController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PremiumSettingsDetailHeader(
                icon: "calendar.badge.clock",
                accent: .blue,
                title: String(localized: "calendarMeeting.settings.title"),
                description: String(localized: "calendarMeeting.settings.description"),
                status: statusText,
                statusColor: statusColor
            )

            SettingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text(String(localized: "calendarMeeting.settings.recordingStart"))
                        .font(.headline)

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

                    Text(String(localized: "calendarMeeting.settings.startModeHelp"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if controller.startMode != .off {
                SettingsCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(String(localized: "calendarMeeting.settings.permissions"))
                            .font(.headline)
                        permissionStatus
                    }
                }

                if controller.calendarAuthorization == .fullAccess {
                    SettingsCard {
                        calendarSelection
                    }

                    SettingsCard {
                        providerSelection
                    }

                    SettingsCard {
                        VStack(alignment: .leading, spacing: 9) {
                            Text(String(localized: "calendarMeeting.settings.stopping"))
                                .font(.headline)

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
                            .disabled(!controller.canEnableAutoStop)
                            .accessibilityIdentifier("calendarMeeting.autoStop")

                            Text(controller.canEnableAutoStop
                                ? String(localized: "calendarMeeting.settings.autoStopHelp")
                                : String(localized: "calendarMeeting.settings.autoStopNotificationsRequired"))
                                .font(.caption)
                                .foregroundStyle(
                                    controller.canEnableAutoStop ? Color.secondary : Color.orange
                                )

                            if !controller.canEnableAutoStop,
                               controller.notificationAuthorization != .notDetermined {
                                Button(String(localized: "calendarMeeting.settings.openNotificationSettings")) {
                                    controller.openNotificationSettings()
                                }
                                .accessibilityIdentifier(
                                    "calendarMeeting.autoStop.notificationSettings"
                                )
                            }
                        }
                    }
                }
            }

            SettingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    Label(
                        String(localized: "calendarMeeting.settings.howItWorks"),
                        systemImage: "waveform.badge.magnifyingglass"
                    )
                    .font(.callout)

                    Label(
                        String(localized: "calendarMeeting.settings.privacy"),
                        systemImage: "hand.raised.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .alert(
            String(localized: "calendarMeeting.permission.requestFailedTitle"),
            isPresented: Binding(
                get: { controller.calendarAccessRequestFailure != nil },
                set: { isPresented in
                    if !isPresented {
                        controller.dismissCalendarAccessRequestFailure()
                    }
                }
            )
        ) {
            Button(String(localized: "OK"), role: .cancel) {
                controller.dismissCalendarAccessRequestFailure()
            }
        } message: {
            Text(String(localized: "calendarMeeting.permission.requestFailedMessage"))
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
        VStack(alignment: .leading, spacing: 10) {
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
                switch controller.calendarAuthorization.permissionAction {
                case .requestAccess:
                    if controller.isCalendarAccessRequestInFlight {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text(String(localized: "calendarMeeting.settings.requestingCalendarAccess"))
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier(
                            "calendarMeeting.permission.calendarRequestProgress"
                        )
                    } else {
                        Button(String(localized: "calendarMeeting.settings.requestCalendarAccess")) {
                            controller.requestCalendarAccess()
                        }
                        .accessibilityIdentifier("calendarMeeting.permission.calendarRequest")
                    }
                case .openSystemSettings:
                    Button(String(localized: "calendarMeeting.settings.openCalendarSettings")) {
                        controller.openCalendarPrivacySettings()
                    }
                    .accessibilityIdentifier("calendarMeeting.permission.calendarSettings")
                case .unavailable, .none:
                    EmptyView()
                }
            }

            if controller.calendarAuthorization == .restricted {
                Text(String(localized: "calendarMeeting.permission.calendarRestrictedHelp"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

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
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "calendarMeeting.settings.calendars"))
                .font(.headline)

            Text(String(localized: "calendarMeeting.settings.calendarsHelp"))
                .font(.caption)
                .foregroundStyle(.secondary)

            if controller.calendars.isEmpty {
                Text(String(localized: "calendarMeeting.settings.noCalendars"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(controller.calendars) { calendar in
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
                    .accessibilityIdentifier("calendarMeeting.calendar.\(calendar.id)")
                }
            }
        }
    }

    private var providerSelection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "calendarMeeting.settings.providers"))
                .font(.headline)

            Text(String(localized: "calendarMeeting.settings.providersHelp"))
                .font(.caption)
                .foregroundStyle(.secondary)

            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                alignment: .leading,
                spacing: 8
            ) {
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

    private var statusColor: Color {
        if controller.startMode != .off,
           controller.calendarAuthorization != .fullAccess {
            return .orange
        }
        switch controller.startMode {
        case .off:
            return .secondary
        case .reminder:
            return .blue
        case .automatic:
            return .green
        }
    }

    private var calendarStatusText: String {
        switch controller.calendarAuthorization {
        case .fullAccess:
            String(localized: "calendarMeeting.permission.calendarGranted")
        case .notDetermined:
            String(localized: "calendarMeeting.permission.calendarNotDetermined")
        case .restricted:
            String(localized: "calendarMeeting.permission.calendarRestricted")
        case .denied, .writeOnly, .unknown:
            String(localized: "calendarMeeting.permission.calendarDenied")
        }
    }

    private var notificationStatusText: String {
        switch controller.notificationAuthorization {
        case .authorized:
            String(localized: "calendarMeeting.permission.notificationsGranted")
        case .notDetermined:
            String(localized: "calendarMeeting.permission.notificationsNotDetermined")
        case .denied, .provisional, .ephemeral, .unknown:
            String(localized: "calendarMeeting.permission.notificationsDenied")
        }
    }
}
