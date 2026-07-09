import AppKit
import Foundation
import UserNotifications

/// Background attention: system notifications when LiquidCode is not frontmost.
/// Pure helpers stay testable; delivery is MainActor-bound.
enum AttentionNotifications {
    static let categoryPermission = "liquidcode.permission"
    static let categoryTurnDone = "liquidcode.turn_completed"
    static let categoryQuestion = "liquidcode.question"
    static let categoryPlan = "liquidcode.plan_review"

    /// True when the app is not the active frontmost application.
    static func shouldNotifyWhileInactive(isAppActive: Bool) -> Bool {
        !isAppActive
    }

    static func isInteractionAttention(_ permission: PermissionRequest) -> Bool {
        switch InteractionAdapter(permission: permission).kind {
        case .permission, .question, .planReview:
            return true
        }
    }

    static func title(for permission: PermissionRequest) -> String {
        switch InteractionAdapter(permission: permission).kind {
        case .question:
            return "Answer needed"
        case .planReview:
            return "Plan ready for review"
        case .permission:
            return "Permission needed"
        }
    }

    static func body(for permission: PermissionRequest) -> String {
        let summary = permission.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if summary.isEmpty {
            return permission.toolName
        }
        return "\(permission.toolName): \(summary)"
    }

    static func category(for permission: PermissionRequest) -> String {
        switch InteractionAdapter(permission: permission).kind {
        case .question: return categoryQuestion
        case .planReview: return categoryPlan
        case .permission: return categoryPermission
        }
    }

    static func turnCompletedTitle() -> String {
        "Turn completed"
    }

    static func turnCompletedBody(sessionTitle: String?) -> String {
        if let sessionTitle, !sessionTitle.isEmpty {
            return sessionTitle
        }
        return "Claude finished a turn"
    }
}

@MainActor
final class AttentionNotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AttentionNotificationService()

    private var authorizationRequested = false

    func configure() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        requestAuthorizationIfNeeded()
    }

    func requestAuthorizationIfNeeded() {
        guard !authorizationRequested else {
            return
        }
        authorizationRequested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in
            // Authorization result is advisory; delivery fails soft if denied.
        }
    }

    func postPermission(_ permission: PermissionRequest, enabled: Bool) {
        guard enabled, AttentionNotifications.shouldNotifyWhileInactive(isAppActive: NSApp.isActive) else {
            return
        }
        guard AttentionNotifications.isInteractionAttention(permission) else {
            return
        }
        requestAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = L(AttentionNotifications.title(for: permission))
        content.body = AttentionNotifications.body(for: permission)
        content.sound = .default
        content.categoryIdentifier = AttentionNotifications.category(for: permission)
        content.userInfo = [
            "sessionID": permission.sessionID,
            "permissionID": permission.id,
            "kind": "permission"
        ]
        deliver(identifier: "perm-\(permission.id)", content: content)
    }

    func postTurnCompleted(sessionID: String, sessionTitle: String?, enabled: Bool) {
        guard enabled, AttentionNotifications.shouldNotifyWhileInactive(isAppActive: NSApp.isActive) else {
            return
        }
        requestAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = L(AttentionNotifications.turnCompletedTitle())
        content.body = AttentionNotifications.turnCompletedBody(sessionTitle: sessionTitle)
        content.sound = .default
        content.categoryIdentifier = AttentionNotifications.categoryTurnDone
        content.userInfo = [
            "sessionID": sessionID,
            "kind": "turn_completed"
        ]
        deliver(identifier: "turn-\(sessionID)-\(UUID().uuidString)", content: content)
    }

    private func deliver(identifier: String, content: UNMutableNotificationContent) {
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    // Foreground: never present banners — the in-app cards already cover it.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let sessionID = info["sessionID"] as? String
        // Hop to MainActor for AppModel, then complete the system callback.
        Task { @MainActor in
            if let sessionID {
                AttentionNotificationRouter.shared.openSession(sessionID)
            }
        }
        completionHandler()
    }
}

/// Bridges notification taps back into the live AppModel without retaining it forever.
@MainActor
final class AttentionNotificationRouter {
    static let shared = AttentionNotificationRouter()
    weak var model: AppModel?

    func bind(_ model: AppModel) {
        self.model = model
    }

    func openSession(_ sessionID: String) {
        guard let model else {
            return
        }
        LiquidCodeMainWindowController.shared.show(model: model)
        model.selectSession(sessionID)
        NSApp.activate(ignoringOtherApps: true)
    }
}
