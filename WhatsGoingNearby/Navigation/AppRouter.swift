//
//  AppRouter.swift
//  WhatsGoingNearby
//
//  Created by Victor Ordozgoite on 08/08/25.
//

import Foundation

/// Ponto único de decisão para a navegação que vem de fora da UI — push notification e
/// banner in-app.
///
/// As telas continuam navegando pelos seus próprios coordinators; o router entra só quando
/// algo externo precisa levar o usuário a um destino, porque essa é a única situação em que
/// é preciso saber, ao mesmo tempo, qual aba está selecionada, o que já está na pilha e para
/// onde ir. Concentrar isso aqui é o que evita espalhar a decisão entre AppDelegate,
/// NotificationManager e Views.
@MainActor
final class AppRouter: ObservableObject {

    static let shared = AppRouter()

    enum Tab: Int, Hashable {
        case home
        case chats
        case account
    }

    /// Pedido para trazer ao fim uma conversa que já está na tela.
    ///
    /// Carrega um token porque duas notificações seguidas da mesma conversa são dois pedidos
    /// distintos: sem ele, o segundo seria indistinguível do primeiro e passaria batido.
    struct ChatFocusRequest: Equatable {
        let chatId: String
        let token: UUID
    }

    @Published var selectedTab: Tab = .home

    @Published private(set) var chatFocusRequest: ChatFocusRequest?

    let homeNav = NavigationCoordinator()
    let chatNav = NavigationCoordinator()
    let accountNav = NavigationCoordinator()

    private init() {}

    func coordinator(for tab: Tab) -> NavigationCoordinator {
        switch tab {
        case .home: return homeNav
        case .chats: return chatNav
        case .account: return accountNav
        }
    }

    func resetSession() {
        selectedTab = .home
        chatFocusRequest = nil
        homeNav.goToRoot()
        chatNav.goToRoot()
        accountNav.goToRoot()
    }

    /// Conversa que o usuário está efetivamente vendo: só o topo da pilha da aba visível.
    ///
    /// Uma conversa empilhada em outra aba, ou coberta por outra tela, não conta — do ponto
    /// de vista do usuário ele não está nela.
    var currentChatId: String? {
        coordinator(for: selectedTab).topChatId
    }
}

// MARK: - Notification Routing

extension AppRouter {
    /// Trata uma rota anunciada por uma notificação (push ou banner in-app).
    func handleNotificationRoute(_ route: AppRoute) {
        switch route {
        case .messages(let chat):
            openChat(chat)
        default:
            // As demais notificações continuam sendo tratadas por quem as recebe.
            break
        }
    }

    /// Leva o usuário até `chat` pelo fluxo normal de navegação do app.
    ///
    /// A identidade da rota é o `chatId`, e não a View: é isso que impede a mesma conversa de
    /// aparecer duas vezes seguidas na pilha, mesmo quando os dois destinos são construídos
    /// a partir de payloads diferentes.
    func openChat(_ chat: FormattedChat) {
        // A conversa já está na tela. Empilhar de novo só criaria a cópia que o usuário
        // teria de fechar antes de voltar para a conversa de baixo — mas a notificação
        // continua sendo um pedido para ver a mensagem que a motivou, e sem navegação nova
        // nada levaria a conversa até ela.
        guard currentChatId != chat.id else {
            chatFocusRequest = ChatFocusRequest(chatId: chat.id, token: UUID())
            return
        }

        // Vindo de qualquer outro lugar — lista de conversas, outra conversa ou outra aba —
        // a hierarquia final é sempre `Chats -> Messages(chat)`. Substituir a pilha em vez de
        // empilhar é o que garante que um único "voltar" leve à lista, inclusive quando o
        // usuário estava dentro de outra conversa.
        selectedTab = .chats
        chatNav.setStack([.messages(chat)])
    }
}
