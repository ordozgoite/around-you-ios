//
//  WhatsGoingNearbyApp.swift
//  WhatsGoingNearby
//
//  Created by Victor Ordozgoite on 13/02/24.
//

import SwiftUI
import FirebaseCore
import FirebaseAuth
import FirebaseMessaging
import GoogleSignIn
import UserNotifications
import BackgroundTasks
import OSLog

final class AppDelegate: NSObject, UIApplicationDelegate {

    private let locationManager = LocationManager.shared
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "AroundYou",
        category: "EngagementRefresh"
    )

    func application( _ application: UIApplication, didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // FirebaseApp.configure()
        
        Messaging.messaging().isAutoInitEnabled = true
        
        Messaging.messaging().delegate = self
        
        let authOptions: UNAuthorizationOptions = [.alert, .badge, .sound]
        UNUserNotificationCenter.current().requestAuthorization(options: authOptions, completionHandler: { _, _ in })
        
        application.registerForRemoteNotifications()
        
        Messaging.messaging().token { token, error in
            if let error {
                print("Error fetching FCM registration token: \(error)")
            } else if let token {
                print("FCM registration token: \(token)")
            }
        }
        
        let didRegisterTask = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Constants.updateLocBGTaskId,
            using: nil
        ) { task in
            guard let task = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self.handleTask(task: task)
        }
        logger.info("Background refresh handler registered: \(didRegisterTask, privacy: .public)")
        
        schedule()

        printBGTaskStats()

#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-RunEngagementRefreshDiagnostic") {
            Task {
                let success = await performEngagementRefresh()
                logger.info("Manual engagement diagnostic completed: \(success, privacy: .public)")
            }
        }
#endif

        return true
    }

    private func printBGTaskStats() {
        logger.info("Scheduled count: \(LocalState.bgTaskScheduledCount, privacy: .public)")
        logger.info("Execution count: \(LocalState.bgTaskRunCount, privacy: .public)")
        logger.info("Error count: \(LocalState.bgTaskErrorCount, privacy: .public)")
        logger.info("Engagement notification count: \(LocalState.engagementNotificationCount, privacy: .public)")
        logger.info("Last notification timestamp: \(LocalState.lastNotificationTime, privacy: .public)")
    }

    private func handleTask(task: BGAppRefreshTask) {
        LocalState.bgTaskRunCount += 1
        logger.info("Background engagement refresh started")

        schedule()

        let work = Task {
            let success = await performEngagementRefresh()
            let completedBeforeExpiration = success && !Task.isCancelled
            task.setTaskCompleted(success: completedBeforeExpiration)
            logger.info("Background engagement refresh completed: \(completedBeforeExpiration, privacy: .public)")
        }

        task.expirationHandler = {
            self.logger.error("Background engagement refresh expired")
            work.cancel()
            LocalState.bgTaskErrorCount += 1
        }
    }

    private func schedule() {
        guard let nextBGTaskTime = Calendar.current.date(
            byAdding: .hour,
            value: Constants.BACKGROUND_TASK_DELAY_HOURS,
            to: Date()
        ) else {
            LocalState.bgTaskErrorCount += 1
            logger.error("Unable to calculate the next background refresh date")
            return
        }

        BGTaskScheduler.shared.getPendingTaskRequests { requests in
            let matchingRequests = requests.filter { $0.identifier == Constants.updateLocBGTaskId }
            self.logger.info("Pending engagement refresh requests: \(matchingRequests.count, privacy: .public)")
            guard matchingRequests.isEmpty else { return }

            do {
                let newTask = BGAppRefreshTaskRequest(identifier: Constants.updateLocBGTaskId)
                newTask.earliestBeginDate = nextBGTaskTime
                try BGTaskScheduler.shared.submit(newTask)
                LocalState.bgTaskScheduledCount += 1
                self.logger.info("Background engagement refresh submitted")
            } catch {
                LocalState.bgTaskErrorCount += 1
                self.logger.error("Background refresh submission failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private enum NearByCheckResult {
        case postFound
        case noPostFound
        case error
    }

    private func performEngagementRefresh() async -> Bool {
        switch await checkNearByPost() {
        case .postFound:
            guard !Task.isCancelled else { return false }
            switch await notifyNearByPost() {
            case .scheduled:
                LocalState.engagementNotificationCount += 1
                return true
            case .delayed:
                return true
            case .unauthorized:
                logger.notice("Nearby publication found, but notification permission is unavailable")
                return true
            case .failed:
                LocalState.bgTaskErrorCount += 1
                return false
            }
        case .noPostFound:
            logger.info("Nearby publication check completed with no result")
            return true
        case .error:
            LocalState.bgTaskErrorCount += 1
            return false
        }
    }

    private func checkNearByPost() async -> NearByCheckResult {
        // A identidade da chamada é o token, não um uid enviado pelo app: a API deduz o usuário
        // do Firebase ID Token. Sem sessão não há o que pedir, e a task termina sem tocar na rede.
        guard let user = Auth.auth().currentUser else {
            logger.notice("Nearby publication request skipped: authenticated user unavailable")
            return .error
        }

        guard let location = locationManager.locationForBackgroundRefresh() else {
            logger.notice("Nearby publication request skipped: recent valid location unavailable")
            return .error
        }

        // Token obtido na hora da execução, nunca guardado pelo app: o SDK devolve do cache e só
        // vai à rede quando está perto de expirar — o que é o caso comum aqui, já que a task roda
        // de horas em horas.
        guard let token = try? await user.getIDToken() else {
            logger.error("Nearby publication request skipped: unable to obtain a Firebase ID token")
            return .error
        }

        guard !Task.isCancelled else { return .error }

        logger.info("Checking for a nearby publication using cached location")

        let result = await AYServices.shared.checkNearByPublications(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            token: token
        )

        switch result {
        case .success:
            logger.info("Nearby publication found")
            return .postFound
        case .failure(.dataNotFound):
            return .noPostFound
        case .failure(let error):
            logger.error("Nearby publication request failed: \(error.customMessage, privacy: .public)")
            return .error
        }
    }
    
    func application(_: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("Oh no! Failed to register for remote notifications with error \(error)")
    }
    
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Messaging.messaging().apnsToken = deviceToken
    }
}

extension AppDelegate: MessagingDelegate {
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        print("Firebase registration token: \(String(describing: fcmToken))")
        
        let dataDict: [String: String] = ["token": fcmToken ?? ""]
        NotificationCenter.default.post(
            name: Notification.Name("FCMToken"),
            object: nil,
            userInfo: dataDict
        )
        
        if let token = fcmToken {
            LocalState.userRegistrationToken = token
        }
    }
}


@main
struct WhatsGoingNearbyApp: App {
    init() {
        FirebaseApp.configure()
        print("✅ Firebase configured in App init")
    }
    
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate

    @Environment(\.scenePhase) private var scenePhase

    @StateObject var notificationManager = NotificationManager()
    @StateObject private var router = AppRouter.shared
    @StateObject var authVM = AuthenticationViewModel()
    @StateObject private var socket = SocketService.shared
    @StateObject private var locationManager = LocationManager.shared
    @StateObject private var placesVM = PlacesViewModel()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(notificationManager)
                .environmentObject(router)
                .environmentObject(authVM)
                .environmentObject(socket)
                .environmentObject(locationManager)
                .environmentObject(placesVM)
                .onChange(of: authVM.authenticationState) { state in
                    guard state == .unauthenticated else { return }
                    resetSession()
                }
                .onChange(of: scenePhase) { phase in
                    if phase == .active {
                        socket.handleAppDidBecomeActive()
                        // Retoma o que não chegou a sair. Os segundos que o sistema concede depois
                        // de o app ir para o segundo plano cobrem o caso comum, mas não quem
                        // encerra pelo app switcher ou fica sem rede — para esses, voltar ao app é
                        // a próxima oportunidade. Reenviar em lote é seguro porque cada mensagem
                        // leva a chave de idempotência que a API usa para reconhecer a repetição.
                        MessageOutbox.shared.retryFailedMessages()
                    }
                }
                // O app desliga o proxy de AppDelegate do Firebase, então o retorno do fluxo do
                // Google precisa ser entregue ao SDK explicitamente.
                .onOpenURL { url in
                    _ = GIDSignIn.sharedInstance.handle(url)
                }
        }
    }

    @MainActor
    private func resetSession() {
        MessageOutbox.shared.resetSession()
        PersistenceController.shared.wipe()
        router.resetSession()
        placesVM.resetSession()
        PublicationViewTracker.shared.clearSession()
        notificationManager.resetSession()
        socket.resetSession()
    }
}
