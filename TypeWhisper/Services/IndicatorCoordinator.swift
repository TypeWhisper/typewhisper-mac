import Foundation
import AppKit
import Combine

/// Coordinates the display of different indicator styles (Notch vs Overlay).
@MainActor
final class IndicatorCoordinator {
    private let notchPanel = NotchIndicatorPanel()
    private let overlayPanel = OverlayIndicatorPanel()
    private let minimalPanel = MinimalIndicatorPanel()
    private var cancellables = Set<AnyCancellable>()

    func startObserving() {
        let vm = DictationViewModel.shared

        // When style changes, dismiss the inactive panel and show the active one
        vm.$indicatorStyle
            .receive(on: DispatchQueue.main)
            .sink { [weak self] style in
                self?.switchStyle(style, vm: vm)
            }
            .store(in: &cancellables)

        // Both panels observe state; the coordinator and panels gate which one is active
        notchPanel.startObserving()
        overlayPanel.startObserving()
        minimalPanel.startObserving()
    }

    private func switchStyle(_ style: IndicatorStyle, vm: DictationViewModel) {
        switch style {
        case .notch:
            overlayPanel.dismiss()
            minimalPanel.dismiss()
            notchPanel.updateVisibility(state: vm.state, vm: vm)
        case .overlay:
            notchPanel.dismiss()
            minimalPanel.dismiss()
            overlayPanel.updateVisibility(state: vm.state, vm: vm)
        case .minimal:
            notchPanel.dismiss()
            overlayPanel.dismiss()
            minimalPanel.updateVisibility(state: vm.state, vm: vm)
        }
    }
}
