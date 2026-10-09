import AppKit
import OSLog
import SwiftUI

/// Only settings windows participate in Dock lifetime. Discovery is separate
/// from opening: a retained SwiftUI view can update after its window closes.
@MainActor final class SettingsDockController: NSObject {
    static let shared = SettingsDockController()

    private final class Registration {
        weak var window: NSWindow?
        var isOpen = false
        var hasClosed = false
        var visibilityObservation: NSKeyValueObservation?
        init(_ window: NSWindow) { self.window = window }
    }

    private let setPolicy: (NSApplication.ActivationPolicy) -> Bool
    private let activate: () -> Void
    private let logger = Logger(subsystem: "com.comeg.runwu", category: "settings-dock")
    private var registrations: [ObjectIdentifier: Registration] = [:]
    private var appliedPolicy: NSApplication.ActivationPolicy?
    private(set) var lastPolicyChangeSucceeded: Bool?

    init(setPolicy: @escaping (NSApplication.ActivationPolicy) -> Bool = {
            NSApp.activationPolicy() == $0 || NSApp.setActivationPolicy($0)
        },
        activate: @escaping () -> Void = { NSApp.activate(ignoringOtherApps: true) }) {
        self.setPolicy = setPolicy
        self.activate = activate
        super.init()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(windowWillClose(_:)), name: NSWindow.willCloseNotification, object: nil)
        center.addObserver(self, selector: #selector(windowBecameKey(_:)), name: NSWindow.didBecomeKeyNotification, object: nil)
        center.addObserver(self, selector: #selector(windowBecameKey(_:)), name: NSWindow.didBecomeMainNotification, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    var openSettingsWindowCount: Int {
        registrations.values.filter { $0.window != nil && $0.isOpen }.count
    }

    func start() { updatePolicy() }

    func registerSettingsWindow(_ window: NSWindow) {
        let id = ObjectIdentifier(window)
        // Object identifiers can be reused after a weakly held window dies.
        if registrations[id]?.window !== window {
            let registration = Registration(window)
            registrations[id] = registration
            registration.visibilityObservation = window.observe(\.isVisible, options: [.old, .new]) { [weak self] window, change in
                // AppKit window ordering is confined to the main thread. Only
                // a real hidden-to-shown transition can reopen a closed cache.
                guard change.oldValue == false, change.newValue == true else { return }
                MainActor.assumeIsolated { self?.markOpen(window) }
            }
        }
        let registration = registrations[id]!
        if !registration.hasClosed && (window.isVisible || window.isMiniaturized) {
            markOpen(window)
        }
    }

    func showSettingsWindow(_ window: NSWindow) {
        registerSettingsWindow(window)
        markOpen(window)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.orderFrontRegardless()
        window.makeKey()
        activate()
    }

    /// Reopen must restore settings even if an unrelated window is visible.
    @discardableResult func restoreOpenSettingsWindow() -> Bool {
        guard let window = registrations.values.first(where: { $0.isOpen && $0.window != nil })?.window else {
            return false
        }
        showSettingsWindow(window)
        return true
    }

    private func markOpen(_ window: NSWindow) {
        guard let registration = registrations[ObjectIdentifier(window)], registration.window === window else { return }
        let wasOpen = registration.isOpen
        registration.isOpen = true
        registration.hasClosed = false
        updatePolicy()
        if !wasOpen {
            // Changing accessory to regular can temporarily surrender key
            // status. Finish activation after AppKit processes that change.
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window,
                      self.registrations[ObjectIdentifier(window)]?.isOpen == true,
                      window.isVisible, !window.isMiniaturized else { return }
                self.activate()
                window.orderFrontRegardless()
                window.makeKey()
            }
        }
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let registration = registrations[ObjectIdentifier(window)], registration.window === window else { return }
        // willClose is synchronous and isVisible can still be true here.
        registration.isOpen = false
        registration.hasClosed = true
        updatePolicy()
    }

    @objc private func windowBecameKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window.isKeyWindow || window.isMainWindow else { return }
        markOpen(window)
    }

    private func updatePolicy() {
        registrations = registrations.filter { $0.value.window != nil }
        let desired: NSApplication.ActivationPolicy = openSettingsWindowCount == 0 ? .accessory : .regular
        guard appliedPolicy != desired else { return }
        let succeeded = setPolicy(desired)
        lastPolicyChangeSucceeded = succeeded
        if succeeded { appliedPolicy = desired }
        else { logger.error("Failed to set settings activation policy \(desired.rawValue, privacy: .public)") }
    }
}

/// Shared by the hand-built window and SwiftUI Settings scene; never replaces
/// either window's delegate and never infers closure from view disappearance.
struct SettingsWindowHook: NSViewRepresentable {
    let controller: SettingsDockController
    let title: String

    func makeNSView(context: Context) -> SettingsWindowHookView {
        SettingsWindowHookView(controller: controller, title: title)
    }

    func updateNSView(_ view: SettingsWindowHookView, context: Context) {
        view.settingsTitle = title
        view.discoverWindow()
    }
}

@MainActor final class SettingsWindowHookView: NSView {
    private let controller: SettingsDockController
    var settingsTitle: String

    init(controller: SettingsDockController, title: String) {
        self.controller = controller
        settingsTitle = title
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        discoverWindow()
    }

    func discoverWindow() {
        guard let window else { return }
        window.title = settingsTitle
        controller.registerSettingsWindow(window)
    }
}
