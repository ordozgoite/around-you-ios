//
//  NotificationManager.swift
//  WhatsGoingNearby
//
//  Created by Victor Ordozgoite on 28/02/24.
//

import Foundation
import SwiftUI
import NotificationCenter

@MainActor
class NotificationManager: NSObject, ObservableObject {
    
    let notificationCenter = UNUserNotificationCenter.current()
    
    var isReady: Bool = false
    var pendingPayload: (() -> Void)? = nil
    
    // Comment
    @Published var publicationId: String?
    @Published var isPublicationDisplayed: Bool = false
    
    // Community Message
    @Published var communityId: String?
    @Published var communityName: String?
    @Published var communityImageUrl: String?
    @Published var isCommunityChatDisplayed: Bool = false
    
    // Discover
    @Published var isPeopleTabDisplayed: Bool = false
    
    override init() {
        super.init()
        notificationCenter.delegate = self
    }

    func resetSession() {
        pendingPayload = nil
        publicationId = nil
        isPublicationDisplayed = false
        communityId = nil
        communityName = nil
        communityImageUrl = nil
        isCommunityChatDisplayed = false
        isPeopleTabDisplayed = false
        Self.clearDeliveredNotificationsAndBadge()
    }
    
}

// MARK: - Process Payload

extension NotificationManager: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_: UNUserNotificationCenter, willPresent _: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let options: UNNotificationPresentationOptions = [.badge, .banner, .sound]
        completionHandler(options)
    }
    
    func userNotificationCenter(_: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        // O payload é lido antes da limpeza para que a navegação não dependa
        // da notificação continuar entregue na Central de Notificações.
        let userInfo = response.notification.request.content.userInfo
        processNotificationPayload(userInfo: userInfo)
        NotificationCenter.default.post(
            name: Notification.Name("didReceiveRemoteNotification"),
            object: nil,
            userInfo: userInfo
        )
        Self.clearDeliveredNotificationsAndBadge()
        completionHandler()
    }
    
    private func processNotificationPayload(userInfo: [AnyHashable: Any]) {
        if let nextView = userInfo["screenToShow"] as? String {
            switch nextView {
            case "comment":
                displayCommentScreen(with: userInfo)
            case "message":
                routeToChat(with: userInfo)
            case "communityMessage":
                displayCommunityMessageScreen(with: userInfo)
            case "discover":
                goToPeopleTab()
            default:
                print("❌ Unknown user info received.")
            }
        }
    }
}

// MARK: - Display Screen

extension NotificationManager {
    private func displayCommentScreen(with userInfo: [AnyHashable: Any]) {
        let displayBlock = {
            if let publicationId = userInfo["publicationId"] as? String {
                self.publicationId = publicationId
                self.isPublicationDisplayed = true
            } else {
                print("❌ Incorrect userInfo to display Comment screen.")
            }
        }
        
        enqueueIfNotReady(displayBlock)
    }
    
    /// A conversa é aberta pela navegação normal do app, e não por uma tela apresentada por
    /// cima: quem decide como ajustar a pilha é o `AppRouter`, que sabe o que já está aberto.
    private func routeToChat(with userInfo: [AnyHashable: Any]) {
        let displayBlock = {
            guard
                let chatId = userInfo["chatId"] as? String,
                let username = userInfo["username"] as? String,
                let senderUserUid = userInfo["senderUserUid"] as? String,
                let isLocked = userInfo["isLocked"] as? Bool
            else {
                print("❌ Incorrect userInfo to display Message screen.")
                return
            }

            // O payload traz só o necessário para montar a rota; o resto da conversa é
            // carregado pela própria MessageScreen a partir do chatId.
            let chat = FormattedChat(
                id: chatId,
                chatName: username,
                otherUserUid: senderUserUid,
                chatPic: userInfo["chatPic"] as? String,
                lastMessageAt: nil,
                hasUnreadMessages: false,
                lastMessage: nil,
                isMuted: false,
                isLocked: isLocked
            )

            AppRouter.shared.openChat(chat)
        }

        enqueueIfNotReady(displayBlock)
    }


    private func displayCommunityMessageScreen(with userInfo: [AnyHashable: Any]) {
        let displayBlock = {
            if
                let communityId = userInfo["communityId"] as? String,
                let communityName = userInfo["communityName"] as? String
            {
                self.communityId = communityId
                self.communityName = communityName
                if let communityImageUrl = userInfo["communityImageUrl"] as? String { self.communityImageUrl = communityImageUrl }
                self.isCommunityChatDisplayed = true
            } else {
                print("❌ Incorrect userInfo to display Message screen.")
            }
        }
        
        enqueueIfNotReady(displayBlock)
    }
    
    private func goToPeopleTab() {
        self.isPeopleTabDisplayed = true
    }
    
    private func enqueueIfNotReady(_ displayBlock: @escaping (() -> Void)) {
        if isReady {
            displayBlock()
        } else {
            pendingPayload = displayBlock
        }
    }
}

// MARK: - Delivered Notifications

extension NotificationManager {
    /// Limpa todas as notificações já entregues pelo app e zera o badge do ícone.
    /// Não afeta notificações locais pendentes/agendadas, apenas as já entregues.
    static func clearDeliveredNotificationsAndBadge() {
        let center = UNUserNotificationCenter.current()
        center.removeAllDeliveredNotifications()
        center.setBadgeCount(0) { error in
            if let error {
                print("❌ Unable to reset badge count: \(error.localizedDescription)")
            }
        }
    }

    /// Limpa as notificações já entregues da conversa aberta. O filtro usa o mesmo
    /// `thread-id` que a API envia no payload APNs, então cada conversa limpa só as suas.
    static func removeDeliveredNotifications(forChatId chatId: String) {
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { notifications in
            let identifiers = notifications
                .filter { $0.request.content.threadIdentifier == chatId }
                .map { $0.request.identifier }
            guard !identifiers.isEmpty else { return }
            center.removeDeliveredNotifications(withIdentifiers: identifiers)
        }
    }
}
