enum InitialWindowPresentation: Equatable {
    case setup
    case whatsNew
    case none
}

enum InitialWindowPresentationPolicy {
    static func presentation(
        setupWizardRequired: Bool,
        whatsNewPending: Bool = false
    ) -> InitialWindowPresentation {
        if setupWizardRequired { return .setup }
        return whatsNewPending ? .whatsNew : .none
    }
}
