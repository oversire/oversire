import Foundation

/// Holds page updates while the person uses the page. Main thread only.
/// An update waits until the last signal ends, plus `idle`. Many held updates run once.
final class UpdateGate {
    enum Signal: Hashable { case scroll, mouse, menu, editing, sheet, drag }

    private let idle: TimeInterval
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private var active: Set<Signal> = []
    private var waiting: (() -> Void)?
    // A new signal or a new end makes the old timer stale.
    private var generation = 0

    /// True while an update waits.
    private(set) var isHeld = false {
        didSet { if isHeld != oldValue { onHeldChange?(isHeld) } }
    }
    var onHeldChange: ((Bool) -> Void)?

    init(idle: TimeInterval = 1.0, schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = ChangeBus.mainAfter) {
        self.idle = idle
        self.schedule = schedule
    }

    var isBusy: Bool { !active.isEmpty }

    func begin(_ s: Signal) {
        active.insert(s)
        generation += 1
    }

    func end(_ s: Signal) {
        guard active.remove(s) != nil else { return }
        generation += 1
        armIfIdle()
    }

    /// Runs `apply` now, or after the last signal ends plus `idle`. A newer update replaces a waiting one.
    func submit(_ apply: @escaping () -> Void) {
        guard isBusy || waiting != nil else { apply(); return }
        waiting = apply
        isHeld = true
        armIfIdle()
    }

    /// Runs the waiting update at once, for example from the Show button.
    func flushNow() {
        generation += 1
        let w = waiting
        waiting = nil
        isHeld = false
        w?()
    }

    private func armIfIdle() {
        guard !isBusy, waiting != nil else { return }
        let g = generation
        schedule(idle) { [weak self] in
            guard let self, self.generation == g, !self.isBusy else { return }
            self.flushNow()
        }
    }
}
