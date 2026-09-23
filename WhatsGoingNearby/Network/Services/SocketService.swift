//
//  SocketService.swift
//  ChatApp
//
//  Created by Victor Ordozgoite on 19/01/23.
//

import Foundation
import SocketIO
import UIKit
import OSLog
import FirebaseAuth

enum SocketStatus: String {
    case connected
    case connecting
    case disconnected
}

// MARK: - Realtime Log

/// Log estruturado do fluxo de tempo real do chat.
///
/// Identificadores (uid, chatId, messageId) entram como `private`, então o sistema
/// os redige em produção e só os mostra durante depuração. Rótulos estáveis e
/// contadores entram como `public`. Token e conteúdo de mensagem nunca são registrados.
enum RealtimeLog {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "AroundYou",
        category: "ChatRealtime"
    )

    // Conexão

    static func connecting() {
        logger.info("socket: iniciando conexão")
    }

    static func connected() {
        logger.info("socket: conectado")
    }

    static func disconnected(reason: String) {
        logger.notice("socket: desconectado (\(reason, privacy: .public))")
    }

    static func reconnectAttempt() {
        logger.info("socket: tentando reconectar")
    }

    static func pingSucceeded() {
        logger.debug("socket: ping ok")
    }

    static func foregrounded() {
        logger.info("app: voltou ao primeiro plano, validando conexão")
    }

    static func zombieConnection() {
        logger.error("socket: conectado sem responder ao ping, forçando reconexão")
    }

    static func registered(userUid: String) {
        logger.info("socket: registrado para uid=\(userUid, privacy: .private(mask: .hash))")
    }

    static func authFailure(_ reason: String) {
        logger.error("socket: falha de autenticação (\(reason, privacy: .public))")
    }

    static func socketError(_ description: String) {
        logger.error("socket: erro (\(description, privacy: .public))")
    }

    // Assinaturas

    static func subscribed(event: String, owner: String) {
        logger.info("assinatura: \(event, privacy: .public) owner=\(owner, privacy: .private)")
    }

    static func unsubscribed(owner: String, count: Int) {
        logger.info("assinatura removida: \(count, privacy: .public) listener(s) owner=\(owner, privacy: .private)")
    }

    // Eventos

    static func eventReceived(_ event: String, chatId: String?) {
        logger.info("evento recebido: \(event, privacy: .public) chat=\(chatId ?? "-", privacy: .private(mask: .hash))")
    }

    static func eventIgnored(_ event: String, reason: String) {
        logger.info("evento ignorado: \(event, privacy: .public) motivo=\(reason, privacy: .public)")
    }

    static func parseFailure(event: String, error: Error) {
        logger.error("falha de parsing: \(event, privacy: .public) erro=\(String(describing: error), privacy: .public)")
    }

    // Mesclagem e sincronização

    static func merged(source: String, inserted: Int, updated: Int, reconciled: Int, duplicated: Int) {
        logger.info("merge (\(source, privacy: .public)): +\(inserted, privacy: .public) ~\(updated, privacy: .public) ↔\(reconciled, privacy: .public) =\(duplicated, privacy: .public)")
    }

    static func apiSync(source: String, pages: Int, fetched: Int) {
        logger.info("sync API (\(source, privacy: .public)): \(pages, privacy: .public) página(s), \(fetched, privacy: .public) mensagem(ns)")
    }

    static func apiSyncFailure(source: String) {
        logger.error("sync API falhou (\(source, privacy: .public))")
    }

    static func gapDetected(source: String) {
        logger.notice("lacuna detectada em \(source, privacy: .public), buscando páginas anteriores")
    }
}

@MainActor
final class SocketService: ObservableObject {
    static let shared = SocketService()

    /// A reconexão automática da biblioteca fica desligada de propósito.
    ///
    /// O token do handshake é guardado internamente em `SocketIOClient.connectPayload` no primeiro
    /// `connect`, e é esse valor que o `SocketManager` reenvia a cada tentativa automática. Como a
    /// propriedade não é acessível de fora, a biblioteca reconectaria para sempre com um token já
    /// expirado — justamente o que a API passou a recusar. Quem reconecta é o `scheduleReconnect`
    /// abaixo, que obtém um token novo antes de cada tentativa.
    let manager = SocketManager(
        socketURL: URL(string: Constants.API_URL)!,
        config: [
            .log(true),
            .compress,
            .reconnects(false)
        ]
    )

    @Published var socket: SocketIOClient?
    @Published var status: SocketStatus = .disconnected

    /// Incrementado sempre que o app (re)estabelece ou revalida o canal de tempo real:
    /// conexão nova e retorno ao primeiro plano.
    ///
    /// As telas abertas observam este valor para reconciliar com a API. Usar um sinal
    /// próprio em vez de `status` evita recarregar a tela a cada piscada do indicador.
    @Published private(set) var resyncSignal: Int = 0

    /// uid que autenticou a conexão atual. `nil` significa "sem conexão autenticada".
    ///
    /// Serve só para detectar troca de conta: a identidade de verdade é a do token que o servidor
    /// validou no handshake, e o app não tem como (nem precisa) afirmá-la.
    private var connectedUserUid: String?

    /// Impede que duas tentativas de conexão corram juntas — a obtenção do token é assíncrona e
    /// abre uma janela em que `socket.status` ainda não mudou.
    private var isConnecting = false

    /// Conexões derrubadas por nós (logout, troca de conta) não devem disparar reconexão.
    private var isIntentionallyDisconnected = false

    /// Tentativas de reconexão que forçaram a renovação do token, para o handshake recusado não
    /// virar laço apertado. Zera a cada conexão bem-sucedida e a cada mudança de sessão.
    private var authRetryCount = 0
    private let maxAuthRetries = 3
    private let reconnectDelay: Double = 5

    /// Marca que a próxima tentativa precisa renovar o token à força, sobrevivendo aos
    /// reagendamentos que acontecem entre o handshake recusado e a conexão nova.
    private var pendingTokenRefresh = false

    private var reconnectTask: Task<Void, Never>?

    private var listeners: [ListenerKey: UUID] = [:]

    private struct ListenerKey: Hashable {
        let owner: String
        let event: String
    }

    // In-app Notifications
    @Published var notificationQueue: [AppBannerNotification] = []
    @Published var currentNotification: AppBannerNotification? = nil
    private var notificationTimer: Timer?
    private let notificationDuration = 5.0

    private var isValidatingConnection = false

    private init() {
        socket = manager.defaultSocket
        setupSocketEvents()
        startConnectionCheck()
        connectIfNeeded()
    }

    /// Conecta se ainda não houver conexão viva.
    ///
    /// Continua síncrona porque é chamada de contextos que não são async (timer de validação,
    /// mudança de sessão, ciclo de vida do app). O trabalho assíncrono — obter o ID Token — roda
    /// numa `Task` própria.
    func connectIfNeeded() {
        Task { await self.connect(forcingTokenRefresh: false) }
    }

    /// Abre a conexão autenticando o handshake com o Firebase ID Token.
    ///
    /// O token vai no payload do pacote CONNECT (`connect(withPayload:)`), que é o que o servidor
    /// lê como `socket.handshake.auth`. É obtido a cada tentativa e nunca guardado por nós: o
    /// cache e a renovação são do SDK do Firebase, que só vai à rede quando o token está perto de
    /// expirar (ou quando `forcingTokenRefresh` pede).
    private func connect(forcingTokenRefresh: Bool) async {
        guard let socket = socket else { return }

        // Sem sessão Firebase não há o que autenticar. É o estado normal da tela de login, e o
        // timer de validação passa por aqui a cada 15s — por isso não vira log de falha.
        guard let user = Auth.auth().currentUser else { return }

        guard socket.status != .connected, socket.status != .connecting else {
            print("🔄 Já conectado ou conectando. Ignorando nova tentativa.")
            return
        }

        guard !isConnecting else { return }
        isConnecting = true
        defer { isConnecting = false }

        isIntentionallyDisconnected = false
        status = .connecting
        print("🛜 Iniciando conexão...")
        RealtimeLog.connecting()

        do {
            let token = try await user.getIDTokenResult(forcingRefresh: forcingTokenRefresh).token

            // A sessão pode ter mudado enquanto o token era obtido: conectar aqui abriria uma
            // conexão para o usuário anterior.
            guard Auth.auth().currentUser?.uid == user.uid else {
                RealtimeLog.authFailure("sessão mudou durante a obtenção do token")
                status = .disconnected
                return
            }
            guard socket.status != .connected else { return }

            socket.connect(withPayload: ["token": token])
        } catch {
            RealtimeLog.authFailure("falha ao obter o ID Token")
            status = .disconnected
            scheduleReconnect()
        }
    }

    /// Agenda uma nova tentativa de conexão.
    ///
    /// Substitui a reconexão automática da biblioteca. A diferença que importa é que cada
    /// tentativa passa de novo por `connect(forcingTokenRefresh:)`, então o handshake sempre leva
    /// um token atual em vez de repetir o que foi capturado na primeira conexão.
    private func scheduleReconnect(forcingTokenRefresh: Bool = false) {
        // A renovação forçada é pegajosa de propósito. Um handshake recusado dispara `.error` e,
        // logo em seguida, o `.disconnect` do fechamento da conexão — que agendaria uma tentativa
        // comum e reenviaria o mesmo token recusado, apagando a decisão tomada no `.error`.
        pendingTokenRefresh = pendingTokenRefresh || forcingTokenRefresh

        reconnectTask?.cancel()
        RealtimeLog.reconnectAttempt()

        reconnectTask = Task { [weak self] in
            guard let self = self else { return }
            try? await Task.sleep(nanoseconds: UInt64(self.reconnectDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }

            let shouldForceRefresh = self.pendingTokenRefresh
            self.pendingTokenRefresh = false
            await self.connect(forcingTokenRefresh: shouldForceRefresh)
        }
    }

    /// Handshake recusado pela API.
    ///
    /// O caso esperado é o token ter expirado com o socket aberto — a API encerra a conexão nesse
    /// momento. Renovar à força resolve; o teto existe para um token que o servidor recusa por
    /// outro motivo não virar tentativa infinita. Esgotado o teto, resta o retry lento do
    /// `startConnectionCheck`, a cada 15s.
    private func handleUnauthorizedHandshake() {
        guard authRetryCount < maxAuthRetries else {
            RealtimeLog.authFailure("limite de reautenticações atingido, aguardando próxima validação")
            status = .disconnected
            return
        }

        authRetryCount += 1
        RealtimeLog.authFailure("handshake recusado, renovando o ID Token (tentativa \(authRetryCount)/\(maxAuthRetries))")

        connectedUserUid = nil
        socket?.disconnect()
        scheduleReconnect(forcingTokenRefresh: true)
    }

    private static func isUnauthorized(_ description: String) -> Bool {
        description.lowercased().contains("unauthorized")
    }

    private func startConnectionCheck() {
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
            Task { @MainActor in
                await self.validateConnection()
            }
        }
    }

    /// Confirma, por ping, que o socket não está apenas "aparentemente" conectado.
    ///
    /// Quando o ping falha com o cliente ainda em `.connected`, `connect()` seria ignorado
    /// pelo próprio SocketIO e a conexão zumbi ficaria para sempre sem receber eventos —
    /// por isso derrubamos a conexão antes de tentar de novo.
    @discardableResult
    func validateConnection() async -> Bool {
        guard let socket = socket else { return false }
        // O ping tem timeout de 5s e o check periódico roda a cada 15s: sem esta guarda,
        // uma validação lenta e a do retorno ao foreground poderiam se sobrepor.
        guard !isValidatingConnection else { return status == .connected }

        isValidatingConnection = true
        defer { isValidatingConnection = false }

        let isConnected = await isSocketActuallyConnected()

        if isConnected {
            print("✅ Ping ok. Socket está realmente conectado.")
            RealtimeLog.pingSucceeded()
            self.status = .connected
            return true
        }

        print("🔌 Ping falhou. Forçando reconexão.")
        // Uma reconexão em andamento continua sendo "conectando": marcar como desconectado
        // aqui só faria o indicador piscar em vermelho no meio da tentativa.
        if socket.status != .connecting {
            self.status = .disconnected
        }

        if socket.status == .connected {
            RealtimeLog.zombieConnection()
            connectedUserUid = nil
            socket.disconnect()
        }

        connectIfNeeded()
        return false
    }

    func isSocketActuallyConnected(timeout: TimeInterval = 5.0) async -> Bool {
        guard let socket = socket else { return false }
        if socket.status != .connected { return false }

        return await withCheckedContinuation { continuation in
            socket.emitWithAck("ping-check").timingOut(after: timeout) { data in
                if let response = data.first as? String, response == "pong" {
                    continuation.resume(returning: true)
                } else {
                    continuation.resume(returning: false)
                }
            }
        }
    }

    private func bumpResyncSignal() {
        resyncSignal &+= 1
    }
}

// MARK: - User Session

extension SocketService {

    func resetSession() {
        handleUserSessionChanged()
        notificationTimer?.invalidate()
        notificationTimer = nil
        notificationQueue.removeAll()
        currentNotification = nil
    }

    /// Deve ser chamado quando a sessão do usuário muda: login, troca de conta ou logout.
    ///
    /// A identidade do socket é fixada pelo servidor no handshake e não muda enquanto a conexão
    /// viver. Por isso trocar de usuário não é mais "reavisar quem sou": é derrubar a conexão da
    /// sessão anterior e abrir uma nova, com o token do usuário atual.
    func handleUserSessionChanged() {
        reconnectTask?.cancel()
        authRetryCount = 0
        pendingTokenRefresh = false

        guard let currentUserUid = Auth.auth().currentUser?.uid else {
            isIntentionallyDisconnected = true
            connectedUserUid = nil
            socket?.disconnect()
            RealtimeLog.disconnected(reason: "logout")
            status = .disconnected
            return
        }

        if let socket = socket, socket.status != .disconnected, connectedUserUid != currentUserUid {
            connectedUserUid = nil
            socket.disconnect()
        }

        connectIfNeeded()
    }
}

// MARK: - Scoped Listeners

extension SocketService {

    /// Registra o listener de `event` pertencente a `owner`.
    ///
    /// Registrar o mesmo par (owner, event) de novo **substitui** o handler anterior em vez de
    /// empilhar outro, e `removeListeners(owner:)` remove apenas os listeners daquele dono.
    /// Isso evita os dois problemas do `socket.off(evento)` global: acumular handlers ao
    /// reentrar numa tela e derrubar o listener de outra tela que continua aberta.
    func addListener(for event: String, owner: String, handler: @escaping NormalCallback) {
        guard let socket = socket else { return }

        let key = ListenerKey(owner: owner, event: event)
        if let existingId = listeners[key] {
            socket.off(id: existingId)
        }

        listeners[key] = socket.on(event, callback: handler)
        RealtimeLog.subscribed(event: event, owner: owner)
    }

    func removeListeners(owner: String) {
        guard let socket = socket else { return }

        let keys = listeners.keys.filter { $0.owner == owner }
        guard !keys.isEmpty else { return }

        for key in keys {
            if let id = listeners.removeValue(forKey: key) {
                socket.off(id: id)
            }
        }
        RealtimeLog.unsubscribed(owner: owner, count: keys.count)
    }
}

// MARK: - Custom Events

extension SocketService {
    private func setupCustomEvents() {
        guard let socket = socket else { return }

        socket.on("message-notification") { data, ack in
            do {
                try self.attemptToDiplayChatMessageNotification(withData: data)
            } catch {
                print("Erro ao decodificar notificação de mensagem: \(error)")
                RealtimeLog.parseFailure(event: "message-notification", error: error)
            }
        }

        // ...
    }

    private func attemptToDiplayChatMessageNotification(withData data: [Any]) throws {
        let notificationData = try self.decodeChatMessageNotification(data)


        let notification = AppBannerNotification(
            title: notificationData.senderUsername,
            subtitle: notificationData.messageText,
            imageUrl: notificationData.senderProfilePicUrl,
            route: .messages(notificationData.chat)
        )

        self.enqueueNotification(notification)
    }


    private func decodeChatMessageNotification(_ message: [Any]) throws -> ChatMessageNotification {
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: message[0], options: [])
            return try JSONDecoder().decode(ChatMessageNotification.self, from: jsonData)
        } catch {
            throw error
        }
    }
}

// MARK: - In-app Notifications

extension SocketService {
    func enqueueNotification(_ notification: AppBannerNotification) {
        notificationQueue.append(notification)
        showNextNotificationIfNeeded()
    }

    private func showNextNotificationIfNeeded() {
        guard currentNotification == nil, !notificationQueue.isEmpty else { return }

        let nextNotification = notificationQueue.removeFirst()
        currentNotification = nextNotification

        notificationTimer?.invalidate()
        notificationTimer = Timer.scheduledTimer(withTimeInterval: notificationDuration, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                self.dismissCurrentNotification()
            }
        }
    }

    func dismissCurrentNotification() {
        currentNotification = nil
        notificationTimer?.invalidate()
        notificationTimer = nil

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.showNextNotificationIfNeeded()
        }
    }
}

// MARK: - Setup Events

extension SocketService {
    private func setupSocketEvents() {
        guard let socket = socket else { return }

        socket.removeAllHandlers()

        setupClientEvents()
        setupCustomEvents()
    }

    private func setupClientEvents() {
        guard let socket = socket else { return }

        socket.on(clientEvent: .connect) { [weak self] _, _ in
            guard let self = self else { return }
            // Chegar aqui já significa handshake aceito: a API só emite `connect` depois de
            // validar o ID Token. Não há mais nada a enviar para provar identidade.
            print("✅ Socket conectado e autenticado")
            RealtimeLog.connected()
            self.status = .connected
            self.authRetryCount = 0
            self.connectedUserUid = Auth.auth().currentUser?.uid
            if let userUid = self.connectedUserUid {
                RealtimeLog.registered(userUid: userUid)
            }
            self.bumpResyncSignal()
        }

        socket.on(clientEvent: .disconnect) { [weak self] data, _ in
            guard let self = self else { return }
            print("📡❌ Socket desconectado")
            RealtimeLog.disconnected(reason: (data.first as? String) ?? "desconhecido")
            self.connectedUserUid = nil
            self.status = .disconnected

            // A API encerra a conexão quando o token expira, e a biblioteca não reconecta sozinha
            // (`.reconnects(false)`): a reconexão é nossa, para levar um token novo.
            guard !self.isIntentionallyDisconnected else { return }
            self.scheduleReconnect()
        }

        // O pacote CONNECT_ERROR do servidor chega como `clientEvent: .error`. É por ele que o
        // `unauthorized` do middleware da API se manifesta.
        //
        // Os parâmetros do callback são `(data, ack)` — antes o primeiro vinha descartado e o log
        // registrava o emissor de ack, não o erro.
        socket.on(clientEvent: .error) { [weak self] data, _ in
            let description = String(describing: data)
            print("❌ Erro no socket: \(description)")
            RealtimeLog.socketError(description)

            guard let self = self, Self.isUnauthorized(description) else { return }
            self.handleUnauthorizedHandshake()
        }
    }
}

// MARK: - App Lifecycle

extension SocketService {
    /// Chamado pelo `scenePhase` do app quando a cena volta a ficar ativa.
    ///
    /// Voltar do background é o caso clássico do socket "conectado" que já não entrega nada:
    /// validamos por ping e, de todo modo, pedimos às telas abertas que reconciliem com a
    /// API — mensagens podem ter chegado enquanto o app dormia.
    ///
    /// O gatilho vem do `scenePhase` e não de `UIApplication.didBecomeActiveNotification`
    /// porque este é um app de ciclo de vida SwiftUI: o observador era registrado na criação
    /// do `@StateObject`, que o SwiftUI faz preguiçosamente no primeiro `body`, e podia
    /// perder a notificação inicial.
    func handleAppDidBecomeActive() {
        print("🔄 App voltou ao primeiro plano. Validando conexão.")
        RealtimeLog.foregrounded()
        Task { @MainActor in
            await self.validateConnection()
            self.bumpResyncSignal()
        }
    }
}
