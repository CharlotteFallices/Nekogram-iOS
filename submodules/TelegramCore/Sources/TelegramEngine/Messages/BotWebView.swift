import Foundation
import Postbox
import SwiftSignalKit
import TelegramApi
import MtProtoKit

public enum RequestSimpleWebViewError {
    case generic
}

func _internal_requestSimpleWebView(postbox: Postbox, network: Network, botId: PeerId, url: String, themeParams: [String: Any]?) -> Signal<String, RequestSimpleWebViewError> {
    var serializedThemeParams: Api.DataJSON?
    if let themeParams = themeParams, let data = try? JSONSerialization.data(withJSONObject: themeParams, options: []), let dataString = String(data: data, encoding: .utf8) {
        serializedThemeParams = .dataJSON(data: dataString)
    }
    return postbox.transaction { transaction -> Signal<String, RequestSimpleWebViewError> in
        guard let bot = transaction.getPeer(botId), let inputUser = apiInputUser(bot) else {
            return .fail(.generic)
        }

        var flags: Int32 = 0
        if let _ = serializedThemeParams {
            flags |= (1 << 0)
        }
        return network.request(Api.functions.messages.requestSimpleWebView(flags: flags, bot: inputUser, url: url, themeParams: serializedThemeParams))
        |> mapError { _ -> RequestSimpleWebViewError in
            return .generic
        }
        |> mapToSignal { result -> Signal<String, RequestSimpleWebViewError> in
            switch result {
                case let .simpleWebViewResultUrl(url):
                    return .single(url)
            }
        }
    }
    |> castError(RequestSimpleWebViewError.self)
    |> switchToLatest
}

public enum KeepWebViewError {
    case generic
}

public enum RequestWebViewResult {
    case webViewResult(queryId: Int64, url: String, keepAliveSignal: Signal<Never, KeepWebViewError>)
    case requestConfirmation(botIcon: TelegramMediaFile)
}

public enum RequestWebViewError {
    case generic
}

private func keepWebView(network: Network, flags: Int32, peer: Api.InputPeer, bot: Api.InputUser, queryId: Int64, replyToMessageId: MessageId?) -> Signal<Never, KeepWebViewError> {
    let poll = Signal<Never, KeepWebViewError> { subscriber in
        let signal: Signal<Never, KeepWebViewError> = network.request(Api.functions.messages.prolongWebView(flags: flags, peer: peer, bot: bot, queryId: queryId, replyToMsgId: replyToMessageId?.id))
        |> mapError { _ -> KeepWebViewError in
            return .generic
        }
        |> ignoreValues
        
        return signal.start(error: { error in
            subscriber.putError(error)
        }, completed: {
            subscriber.putCompletion()
        })
    }
    
    return (
        .complete()
        |> suspendAwareDelay(60.0, queue: Queue.concurrentDefaultQueue())
        |> then (poll)
    )
    |> restart
}

func _internal_requestWebView(postbox: Postbox, network: Network, peerId: PeerId, botId: PeerId, url: String?, themeParams: [String: Any]?, replyToMessageId: MessageId?) -> Signal<RequestWebViewResult, RequestWebViewError> {
    var serializedThemeParams: Api.DataJSON?
    if let themeParams = themeParams, let data = try? JSONSerialization.data(withJSONObject: themeParams, options: []), let dataString = String(data: data, encoding: .utf8) {
        serializedThemeParams = .dataJSON(data: dataString)
    }
    
    return postbox.transaction { transaction -> Signal<RequestWebViewResult, RequestWebViewError> in
        guard let peer = transaction.getPeer(peerId), let inputPeer = apiInputPeer(peer), let bot = transaction.getPeer(botId), let inputBot = apiInputUser(bot) else {
            return .fail(.generic)
        }

        var flags: Int32 = 0
        if let _ = url {
            flags |= (1 << 1)
        }
        if let _ = serializedThemeParams {
            flags |= (1 << 2)
        }
        var replyToMsgId: Int32?
        if let replyToMessageId = replyToMessageId {
            flags |= (1 << 0)
            replyToMsgId = replyToMessageId.id
        }
        return network.request(Api.functions.messages.requestWebView(flags: flags, peer: inputPeer, bot: inputBot, url: url, themeParams: serializedThemeParams, replyToMsgId: replyToMsgId))
        |> mapError { _ -> RequestWebViewError in
            return .generic
        }
        |> mapToSignal { result -> Signal<RequestWebViewResult, RequestWebViewError> in
            switch result {
                case let .webViewResultConfirmationRequired(bot, users):
                    return postbox.transaction { transaction -> Signal<RequestWebViewResult, RequestWebViewError> in
                        var peers: [Peer] = []
                        for user in users {
                            let telegramUser = TelegramUser(user: user)
                            peers.append(telegramUser)
                        }
                        updatePeers(transaction: transaction, peers: peers, update: { _, updated -> Peer in
                            return updated
                        })
                        
                        if case let .attachMenuBot(_, _, _, attachMenuIcon) = bot, let icon = telegramMediaFileFromApiDocument(attachMenuIcon) {
                            return .single(.requestConfirmation(botIcon: icon))
                        } else {
                            return .complete()
                        }
                    }
                    |> castError(RequestWebViewError.self)
                    |> switchToLatest
                case let .webViewResultUrl(queryId, url):
                    return .single(.webViewResult(queryId: queryId, url: url, keepAliveSignal: keepWebView(network: network, flags: flags, peer: inputPeer, bot: inputBot, queryId: queryId, replyToMessageId: replyToMessageId)))
            }
        }
    }
    |> castError(RequestWebViewError.self)
    |> switchToLatest
}

public enum SendWebViewDataError {
    case generic
}

func _internal_sendWebViewData(postbox: Postbox, network: Network, stateManager: AccountStateManager, botId: PeerId, buttonText: String, data: String) -> Signal<Never, SendWebViewDataError> {
    return postbox.transaction { transaction -> Signal<Never, SendWebViewDataError> in
        guard let bot = transaction.getPeer(botId), let inputBot = apiInputUser(bot) else {
            return .fail(.generic)
        }
        
        return network.request(Api.functions.messages.sendWebViewData(bot: inputBot, randomId: Int64.random(in: Int64.min ... Int64.max), buttonText: buttonText, data: data))
        |> mapError { _ -> SendWebViewDataError in
            return .generic
        }
        |> map { updates -> Api.Updates in
            stateManager.addUpdates(updates)
            return updates
        }
        |> ignoreValues
    }
    |> castError(SendWebViewDataError.self)
    |> switchToLatest
}
