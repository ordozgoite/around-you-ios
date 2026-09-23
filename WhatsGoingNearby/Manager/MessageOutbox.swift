//
//  MessageOutbox.swift
//  WhatsGoingNearby
//
//  Fila de envio das mensagens de conversa privada.
//

import Foundation
import UIKit
import FirebaseAuth
import FirebaseStorage

/// O que aconteceu com uma mensagem que estava saindo.
enum OutboxEvent {
    /// O servidor confirmou a mensagem, e o id temporário deve dar lugar ao definitivo.
    case confirmed(temporaryId: String, message: Message)
    case failed(temporaryId: String)
    case sending(temporaryId: String)
}

/// Dona do envio das mensagens, do toque no botão até a confirmação do servidor.
///
/// Vive fora da tela de propósito. Enquanto a corrente de envio pertencia ao view model, que é
/// `@StateObject` da conversa, sair do chat destruía o view model e cancelava a `Task` no meio —
/// a mensagem ficava parada em "enviando" para sempre, e só era descoberta ao reabrir a conversa.
///
/// Sendo um singleton, o envio continua depois de fechar a conversa, depois de trocar de aba e,
/// pelos poucos segundos que o sistema concede, depois de o app ir para segundo plano.
@MainActor
final class MessageOutbox: ObservableObject {

    static let shared = MessageOutbox()

    private let messageStore: MessageStore

    init(messageStore: MessageStore = .shared) {
        self.messageStore = messageStore
    }

    /// Última coisa que aconteceu na fila. A conversa aberta observa para refletir na tela;
    /// quando não há conversa aberta, ninguém observa e o cache local é o único destino.
    @Published private(set) var lastEvent: OutboxEvent?

    //MARK: - Fila

    /// Corrente de envio: cada mensagem espera a anterior terminar antes de sair.
    ///
    /// O upload da foto demora mais que um POST de texto, então envios paralelos chegariam fora
    /// de ordem ao servidor e a conversa apareceria embaralhada.
    private var pipeline: Task<Void, Never>?
    private var sessionID = UUID()

    /// Mensagens que falharam e estão segurando a corrente até serem reenviadas ou removidas.
    private var blockedSends: [String: CheckedContinuation<Void, Never>] = [:]

    func resetSession() {
        sessionID = UUID()
        pipeline?.cancel()
        pipeline = nil
        lastEvent = nil

        let continuations = Array(blockedSends.values)
        blockedSends.removeAll()
        continuations.forEach { $0.resume() }
    }

    func enqueue(_ message: MessageIntermediary) {
        let sessionID = sessionID
        let previous = pipeline
        pipeline = Task { [weak self] in
            await previous?.value
            await self?.send(message, sessionID: sessionID)
        }
    }

    private func send(_ message: MessageIntermediary, sessionID: UUID) async {
        await deliver(message, sessionID: sessionID)
        guard sessionID == self.sessionID else { return }
        await holdPipeline(ifFailed: message.id)
    }

    /// Segura a corrente enquanto a mensagem estiver falha, para que as seguintes não ultrapassem
    /// uma mensagem que o usuário ainda pode reenviar. Confirmar ou remover a mensagem libera.
    private func holdPipeline(ifFailed messageId: String) async {
        guard messageStore.status(ofMessageWithId: messageId) == .failed else { return }

        await withCheckedContinuation { continuation in
            blockedSends[messageId] = continuation
        }
    }

    func releasePipeline(holdingMessageId messageId: String) {
        blockedSends.removeValue(forKey: messageId)?.resume()
    }

    //MARK: - Envio

    /// Sobe a foto, se houver, e entrega a mensagem à API.
    ///
    /// Separado de `send` porque o reenvio precisa disto e nada mais: passar por `holdPipeline`
    /// guardaria uma segunda continuação para a mesma mensagem e deixaria a corrente presa para
    /// sempre na primeira, que ninguém mais retomaria.
    private func deliver(_ message: MessageIntermediary, sessionID: UUID) async {
        // Os poucos segundos que o sistema concede depois do app sair da tela. Não é garantia de
        // entrega — quem encerra pelo app switcher não roda mais nada —, mas cobre com folga um
        // texto e a maioria dos uploads de foto, que é o caso comum de sair no meio do envio.
        let assertion = UIApplication.shared.beginBackgroundTask(withName: "send-message")
        defer { UIApplication.shared.endBackgroundTask(assertion) }

        let token = await currentToken()
        guard !Task.isCancelled, sessionID == self.sessionID else { return }
        guard let token else {
            markFailed(message)
            return
        }

        let imageUrl: String?
        do {
            imageUrl = try await uploadedImageUrl(for: message.image)
        } catch {
            guard !Task.isCancelled, sessionID == self.sessionID else { return }
            markFailed(message)
            return
        }

        guard !Task.isCancelled, sessionID == self.sessionID else { return }

        // Sem `imageUrl` a mensagem de foto não tem conteúdo nenhum, e a API a recusaria. Falhar
        // aqui é o que preserva os bytes locais para uma nova tentativa.
        guard message.text != nil || imageUrl != nil else {
            markFailed(message)
            return
        }

        let result = await AYServices.shared.postNewMessage(
            chatId: message.chatId,
            text: message.text,
            imageUrl: imageUrl,
            repliedMessageId: message.repliedMessageId,
            // O id temporário é a chave de idempotência: ele sobrevive ao reenvio, então a API
            // reconhece a segunda tentativa como a mesma mensagem em vez de criar uma cópia.
            clientMessageId: message.id,
            token: token
        )

        guard !Task.isCancelled, sessionID == self.sessionID else { return }

        switch result {
        case .success(let confirmed):
            markConfirmed(message, as: confirmed)
        case .failure:
            markFailed(message)
        }
    }

    /// Token obtido na hora do envio, e nunca guardado: o envio pode acontecer bem depois do
    /// toque no botão, e o token que valia ali já teria expirado.
    private func currentToken() async -> String? {
        guard let user = Auth.auth().currentUser else { return nil }
        return try? await user.getIDToken()
    }

    private func uploadedImageUrl(for image: UIImage?) async throws -> String? {
        guard let image else { return nil }

        let reference = Storage.storage().reference().child("post-image/\(UUID().uuidString).jpg")
        guard let data = image.jpegData(compressionQuality: 0.8) else { return nil }

        _ = try await reference.putDataAsync(data)
        return try await reference.downloadURL().absoluteString
    }

    //MARK: - Resultado

    private func markConfirmed(_ message: MessageIntermediary, as confirmed: Message) {
        // O cache é atualizado aqui, e não pela tela: quando a conversa está fechada não existe
        // ninguém para fazê-lo, e a mensagem precisa estar confirmada ao reabrir.
        messageStore.delete(messageId: message.id)
        var intermediary = confirmed.convertMessageToIntermediary(forCurrentUserUid: LocalState.currentUserUid)
        intermediary.status = .sent
        messageStore.upsert([intermediary], chatId: confirmed.chatId)

        lastEvent = .confirmed(temporaryId: message.id, message: confirmed)
        releasePipeline(holdingMessageId: message.id)
    }

    private func markFailed(_ message: MessageIntermediary) {
        var failed = message
        failed.status = .failed
        messageStore.upsert([failed], chatId: message.chatId)

        lastEvent = .failed(temporaryId: message.id)
    }

    //MARK: - Retomada

    /// Reenvia o que ficou pelo caminho.
    ///
    /// Chamado quando a conexão volta e quando o app retorna ao primeiro plano. Só mensagens
    /// falhas entram: é seguro porque cada uma carrega a chave de idempotência que a API usa para
    /// reconhecer a repetição — sem ela, esta função seria uma máquina de duplicar mensagens.
    func retryFailedMessages(chatId: String? = nil) {
        let pending = messageStore.loadFailedMessages(chatId: chatId)
        guard !pending.isEmpty else { return }
        let sessionID = sessionID

        // Cada falha deixou a corrente presa na própria mensagem, esperando o reenvio. Soltar
        // antes de re-enfileirar é o que evita o impasse: sem isto, a nova tentativa entraria na
        // corrente atrás da retenção que ela mesma viria resolver, e nunca começaria.
        for message in pending {
            releasePipeline(holdingMessageId: message.id)
        }

        let previous = pipeline
        pipeline = Task { [weak self] in
            await previous?.value
            guard let self, sessionID == self.sessionID else { return }
            // Entregues em ordem, e sem voltar a segurar a corrente: a leva já está ordenada por
            // data, e uma nova falha aqui não deve impedir as seguintes de tentarem.
            for message in pending {
                guard sessionID == self.sessionID else { return }
                self.lastEvent = .sending(temporaryId: message.id)
                await self.deliver(message, sessionID: sessionID)
            }
        }
    }

    /// Reenvia uma mensagem específica, a pedido do usuário.
    func retry(_ message: MessageIntermediary) async {
        let sessionID = sessionID
        lastEvent = .sending(temporaryId: message.id)
        await deliver(message, sessionID: sessionID)
    }

    /// Esquece uma mensagem que o usuário descartou, liberando a corrente que ela segurava.
    func discard(messageId: String) {
        messageStore.delete(messageId: messageId)
        releasePipeline(holdingMessageId: messageId)
    }
}
