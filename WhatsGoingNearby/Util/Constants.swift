//
//  Constants.swift
//  WhatsGoingNearby
//
//  Created by Victor Ordozgoite on 05/03/24.
//

import Foundation
import CoreLocation

extension Notification.Name {
    static let refreshLocationSensitiveData = Notification.Name("refreshFeed")
    static let updateLocation = Notification.Name("updateLocation")
    static let updateUserProfilePosts = Notification.Name("updateUserProfilePosts")
    static let updateBadge = Notification.Name("updateBadge")
    static let popCommunity = Notification.Name("popCommunity")
    static let goToUsernameScreen = Notification.Name("goToUsernameScreen")
    static let displayRetryGetUserInfoButton = Notification.Name("displayRetryGetUserInfoButton")
    static let launchAnimationFinished = Notification.Name("launchAnimationFinished")
}

struct Constants {
    static let API_URL: String = "https://api.getaroundyou.com" // AWS
//    static let API_URL: String = "https://around-you-3acb9615e8a5.herokuapp.com" // Heroku
//    static let API_URL: String = "http://localhost:3000"    
//    static let API_URL: String = "http://10.0.0.69" // Raspberry (local)
    
    // MARK: - BG Tasks

    /*
     Toda vez que for mudar o Id de uma Background Task, é necessário atualizar o valor na Info Plist!
     */
    
    static let updateLocBGTaskId: String = "ordozgoite.WhatsGoingNearby.backgroundTask.updateLoc"
    
    // MARK: - Images
    
    static let instagramLogoImageName: String = "instagram"
    static let whatsAppLogoImageName: String = "whatsapp"
    
    // MARK: -  User
    
    static let MAX_USERNAME_LENGHT: Int = 20
    static let MAX_NAME_LENGHT: Int = 30
    static let MAX_BIO_LENGHT: Int = 250
    
    // MARK: - Feed
    
    static let MAX_POST_LENGHT = 250
    
    // MARK: - Time and Distance
    
    static let BACKGROUND_TASK_DELAY_HOURS: Int = 1
    static let MAX_BACKGROUND_LOCATION_AGE_SECONDS: TimeInterval = 24 * 60 * 60
    static let MAX_BACKGROUND_LOCATION_ACCURACY_METERS: CLLocationAccuracy = 1_000
    static let NOTIFICATION_DELAY_SECONDS: Int = 4 * 60 * 60
    static let SIGNIFICANT_DISTANCE_METERS: CLLocationDistance = 50
    static let MAX_ELAPSED_TIME_DELETE_MESSAGE_SECONDS: Int = 10 * 60

    // MARK: - Chat Realtime

    /// Janela usada para casar uma mensagem local ainda em envio com a versão confirmada pelo servidor.
    static let MESSAGE_RECONCILIATION_WINDOW_SECONDS: Int = 2 * 60
    /// Limite de páginas buscadas ao fechar uma lacuna de mensagens perdidas durante uma desconexão.
    static let MAX_MESSAGE_RECONCILIATION_PAGES: Int = 5

    /// Mensagens por página, tanto na abertura da conversa quanto no scroll infinito.
    /// Servidores anteriores à opção `limit` ignoram o parâmetro e devolvem 20.
    static let MESSAGES_PAGE_SIZE: Int = 30
    
    //MARK: - Discover Defaults
    
    static let DEFAULT_USER_AGE: Int = 18
    static let DEFAULT_MIN_AGE_PREFERENCE: Int = 25
    static let DEFAULT_MAX_AGE_PREFERENCE: Int = 40
    static let minDiscoverAge: Int = 18
    static let maxDiscoverAge: Int = 99
    
    // MARK: - Community
    
    static let communityDiscaimerMessageId: String = "community_disclaimer_message_id"
    
    // MARK: - Icons
    
    static let communityIconImageName: String = "bubble.left.and.bubble.right"
}
