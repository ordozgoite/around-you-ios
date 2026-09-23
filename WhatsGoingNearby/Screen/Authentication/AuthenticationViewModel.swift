//
//  AuthenticationViewModel.swift
//  WhatsGoingNearby
//
//  Created by Victor Ordozgoite on 13/02/24.
//

import Foundation
import FirebaseAuth
import FirebaseCore
import GoogleSignIn
import AuthenticationServices
import CryptoKit
import SwiftUI

enum AuthenticationState {
    case unauthenticated
    case authenticating
    case authenticated
}

enum AuthenticationFlow: Int, CaseIterable {
    case login
    case signUp
    
    var title: LocalizedStringKey {
        switch self {
        case .login:
            return "Log In"
        case .signUp:
            return "Sign Up"
        }
    }
}

@MainActor
class AuthenticationViewModel: ObservableObject {
    
    @Published var usernameInput: String = ""
    @Published var emailInput: String = ""
    @Published var passwordInput: String = ""
    @Published var flow: AuthenticationFlow = .login
    @Published var isValid  = false
    @Published var authenticationState: AuthenticationState = .unauthenticated
    @Published var overlayError: (Bool, LocalizedStringKey) = (false, "")
    @Published var user: User?
    
    @Published var isUserInfoFetched: Bool = false
    @Published var isLoading: Bool = false
    @Published var isForgotPasswordScreenDisplayed: Bool = false
    @Published var errorMessage: (LocalizedStringKey?, LocalizedStringKey?, LocalizedStringKey?) = (nil, nil, nil)
    
    // User Profile
    @Published var username: String = ""
    @Published var name: String?
    @Published var profilePic: String?
    @Published var biography: String?
    @Published var showProfileInPublicationViews: Bool = true
    @Published var role: UserRole = .user
    @Published var isGettingUserInfo: Bool = false
    
    // Resolvido antes da MainTabView, junto do restante do perfil, para que nenhuma tela precise
    // consultar o papel do usuário depois de já estar visível.
    var isAdmin: Bool {
        role == .admin || role == .superadmin
    }
    
    // User Discover Preferences
    @Published var isUserDiscoverable: Bool = false
    @Published var age: Int = 18
    @Published var gender: Gender = .cisMale
    @Published var interestGenders: Set<Gender> = []
    @Published var minInterestAge: Int = 25
    @Published var maxInterestAge: Int = 40
    @Published var isDiscoverNotificationsEnabled: Bool = true
    
    init() {
        registerAuthStateHandler()
        
        $flow
            .combineLatest($emailInput, $passwordInput)
            .map { flow, email, password in
                flow == .login
                ? !(email.isEmpty || password.isEmpty)
                : !(email.isEmpty || password.isEmpty)
            }
            .assign(to: &$isValid)
    }
    
    private var currentNonce: String?
    
    private var authStateHandler: AuthStateDidChangeListenerHandle?
    
    func registerAuthStateHandler() {
        if authStateHandler == nil {
            authStateHandler = Auth.auth().addStateDidChangeListener { auth, user in
                self.user = user
                self.authenticationState = user == nil ? .unauthenticated : .authenticated
            }
        }
    }
    
    func getFirebaseToken() async throws -> String {
        return try await user?.getIDToken() ?? ""
    }
}

//MARK: - Sign in with Apple

extension AuthenticationViewModel {
    func handleSignInWithAppleRequest(_ request: ASAuthorizationAppleIDRequest) {
        request.requestedScopes = [.fullName, .email]
        let nonce = randomNonceString()
        currentNonce = nonce
        request.nonce = sha256(nonce)
    }
    
    func handleSignInWithAppleCompletion(_ result: Result<ASAuthorization, Error>) {
        if case .failure(let failure) = result {
            print("❌ Error: \(failure)")
        }
        else if case .success(let authorization) = result {
            if let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential {
                guard let nonce = currentNonce else {
                    fatalError("Invalid state: a login callback was received, but no login request was sent.")
                }
                guard let appleIDToken = appleIDCredential.identityToken else {
                    print("Unable to fetch identify token.")
                    return
                }
                guard let idTokenString = String(data: appleIDToken, encoding: .utf8) else {
                    print("Unable to serialise token string from data: \(appleIDToken.debugDescription)")
                    return
                }
                
                let credential = OAuthProvider.credential(withProviderID: "apple.com", idToken: idTokenString, rawNonce: nonce)
                Task {
                    do {
                        _ = try await Auth.auth().signIn(with: credential)
                        if let name = appleIDCredential.fullName?.givenName {
                            print("🙋‍♂️ NAME: \(name)")
                            self.name = name
                        }
                    }
                    catch {
                        print("Error authenticating: \(error.localizedDescription)")
                    }
                }
            }
        }
    }
    
    private func randomNonceString(length: Int = 32) -> String {
        precondition(length > 0)
        let charset: [Character] =
        Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remainingLength = length
        
        while remainingLength > 0 {
            let randoms: [UInt8] = (0 ..< 16).map { _ in
                var random: UInt8 = 0
                let errorCode = SecRandomCopyBytes(kSecRandomDefault, 1, &random)
                if errorCode != errSecSuccess {
                    fatalError(
                        "Unable to generate nonce. SecRandomCopyBytes failed with OSStatus \(errorCode)"
                    )
                }
                return random
            }
            
            randoms.forEach { random in
                if remainingLength == 0 {
                    return
                }
                
                if random < charset.count {
                    result.append(charset[Int(random)])
                    remainingLength -= 1
                }
            }
        }
        
        return result
    }
    
    private func sha256(_ input: String) -> String {
        let inputData = Data(input.utf8)
        let hashedData = SHA256.hash(data: inputData)
        let hashString = hashedData.compactMap {
            String(format: "%02x", $0)
        }.joined()
        
        return hashString
    }
}

//MARK: - Sign in with Google

extension AuthenticationViewModel {
    func signInWithGoogle() async {
        // O `clientID` vem do GoogleService-Info.plist. Sem ele o provedor Google ainda não foi
        // habilitado no projeto do Firebase, e não há credencial a pedir.
        guard let clientID = FirebaseApp.app()?.options.clientID else {
            overlayError = (true, ErrorMessage.googleSignInUnavailableErrorMessage)
            return
        }
        guard let presentingViewController = Self.presentingViewController() else {
            overlayError = (true, ErrorMessage.googleSignInErrorMessage)
            return
        }

        authenticationState = .authenticating
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)

        do {
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presentingViewController)

            guard let idToken = result.user.idToken?.tokenString else {
                authenticationState = .unauthenticated
                overlayError = (true, ErrorMessage.googleSignInErrorMessage)
                return
            }

            let credential = GoogleAuthProvider.credential(
                withIDToken: idToken,
                accessToken: result.user.accessToken.tokenString
            )

            // Daqui em diante é o mesmo caminho do e-mail e da Apple: o listener de estado leva à
            // PreparingSessionScreen, que busca o usuário da API e abre a UsernameScreen quando
            // aquele UID ainda não tem um.
            _ = try await Auth.auth().signIn(with: credential)
        }
        catch {
            authenticationState = .unauthenticated
            handleGoogleSignInFailure(error)
        }
    }

    private func handleGoogleSignInFailure(_ error: Error) {
        let nsError = error as NSError

        // Fechar o seletor de contas é decisão do usuário, não erro para exibir.
        if nsError.domain == kGIDSignInErrorDomain,
           nsError.code == GIDSignInError.canceled.rawValue {
            return
        }

        // Já existe conta com este e-mail em outro provedor. Enquanto o account linking não
        // existir, parar aqui é o que impede uma segunda identidade no Firebase — e, por
        // consequência, um segundo usuário da API para a mesma pessoa.
        if nsError.domain == AuthErrorDomain,
           nsError.code == AuthErrorCode.accountExistsWithDifferentCredential.rawValue {
            overlayError = (true, ErrorMessage.providerConflictErrorMessage)
            return
        }

        overlayError = (true, ErrorMessage.googleSignInErrorMessage)
    }

    /// O SDK do Google apresenta o seletor de contas a partir de um `UIViewController`.
    private static func presentingViewController() -> UIViewController? {
        let keyWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }

        var controller = keyWindow?.rootViewController
        while let presented = controller?.presentedViewController {
            controller = presented
        }
        return controller
    }
}

//MARK: - Email and Password Authentication

extension AuthenticationViewModel {
    func signInWithEmailPassword() async -> Bool {
        authenticationState = .authenticating
        do {
            let authResult = try await Auth.auth().signIn(withEmail: self.emailInput, password: self.passwordInput)
            user = authResult.user
            print("🤝 User \(authResult.user.uid) signed in.")
            return true
        }
        catch  {
            print(error)
            overlayError = (true, LocalizedStringKey(stringLiteral: error.localizedDescription))
            authenticationState = .unauthenticated
            return false
        }
    }
    
    func signUpWithEmailPassword() async -> Bool {
        authenticationState = .authenticating
        do  {
            let authResult = try await Auth.auth().createUser(withEmail: emailInput, password: passwordInput)
            user = authResult.user
            print("🤝 User \(authResult.user.uid) signed in.")
            return true
        }
        catch {
            print(error)
            overlayError = (true, LocalizedStringKey(stringLiteral: error.localizedDescription))
            authenticationState = .unauthenticated
            return false
        }
    }
    
    func signOut() {
        do {
            try Auth.auth().signOut()
            // O Firebase encerra a sessão, mas o SDK do Google mantém o próprio estado: sem isto,
            // um logout explícito ainda deixaria a conta Google pronta para reautenticar sozinha.
            GIDSignIn.sharedInstance.signOut()
            PublicationViewTracker.shared.clearSession()
            authenticationState = .unauthenticated
            resetUserInfo()
            resetInputs()
        }
        catch {
            overlayError = (true, LocalizedStringKey(stringLiteral: error.localizedDescription))
        }
    }
    
    func deleteAccount() async -> Bool {
        do {
            let isUserDeleted = try await deleteUser()
            if !isUserDeleted { return false }
            
            try await user?.delete()
            GIDSignIn.sharedInstance.signOut()
            authenticationState = .unauthenticated
            resetUserInfo()
            resetInputs()
            return true
        }
        catch {
            overlayError = (true, LocalizedStringKey(stringLiteral: error.localizedDescription))
            return false
        }
    }
    
    func sendPasswordReset() async -> Bool {
        self.isLoading = true
        do {
            try await Auth.auth().sendPasswordReset(withEmail: emailInput)
            self.isLoading = false
            return true
        } catch {
            overlayError = (true, LocalizedStringKey(stringLiteral: error.localizedDescription))
            self.isLoading = false
            return false
        }
    }
}

//MARK: - AY Methods

extension AuthenticationViewModel {
    func postNewUser(username: String, name: String?, token: String) async -> Bool {
        let result = await AYServices.shared.postNewUser(username: username, name: name, userRegistrationToken: LocalState.userRegistrationToken, token: token)
        
        switch result {
        case .success(let user):
            updateCurrentInformation(for: user)
        case .failure(let error):
            if error == .conflict {
                overlayError = (true, ErrorMessage.usernameInUseMessage)
                return true
            } else {
                signOut()
                overlayError = (true, ErrorMessage.postUserErrorMessage)
            }
        }
        return false
    }
    
    func getUserInfo(token: String) async {
        isGettingUserInfo = true
        defer { isGettingUserInfo = false }
        
        let result = await AYServices.shared.getUserInfo(userRegistrationToken: LocalState.userRegistrationToken.isEmpty ? nil : LocalState.userRegistrationToken, preferredLanguage: getPreferredLanguage(), token: token)
        
        switch result {
        case .success(let user):
            updateCurrentInformation(for: user)
        case .failure(let error):
            if error == .dataNotFound {
                if usernameInput.isEmpty {
                    goToUsernameScreen()
                } else {
                    let isUsernameConflict = await postNewUser(username: usernameInput, name: nil, token: token)
                    if isUsernameConflict { goToUsernameScreen() }
                }
            } else if error == .forbidden {
                signOut()
                overlayError = (true, ErrorMessage.permaBannedErrorMessage)
            } else if error == .unauthorized {
                await getUserBanExpirationDate(token: token)
            } else {
                /*
                 🚨 O FAMOSO ERRO ESTÁ AQUI!!!
                 Esse erro faz com que, às vezes, ao retornar ao app, o usuário esteja deslogado (Corrigido?)
                 */
                
                displayRetryButton()
                overlayError = (true, ErrorMessage.getUserInfo)
                // signOut()
            }
        }
    }
    
    private func goToUsernameScreen() {
        NotificationCenter.default.post(name: .goToUsernameScreen, object: nil)
    }
    
    private func displayRetryButton() {
        NotificationCenter.default.post(name: .displayRetryGetUserInfoButton, object: nil)
    }
    
    private func deleteUser() async throws -> Bool {
        let token = try await getFirebaseToken()
        let result = await AYServices.shared.deleteUser(token: token)
        
        switch result {
        case .success:
            return true
        case .failure:
            return false
        }
    }
    
    private func updateCurrentInformation(for user: MongoUser) {
        print("🌎 updateCurrentInformation: \(user)")
        self.username = user.username
        self.name = user.name ?? ""
        self.profilePic = user.profilePic
        self.biography = user.biography
        self.showProfileInPublicationViews = user.showProfileInPublicationViews ?? true
        self.role = UserRole(rawValue: user.role ?? "") ?? .user
        self.isUserInfoFetched = true
        
        persistNewProfile(forUser: user)
    }
    
    func retrieveUserProfile() {
        self.username = LocalState.username
        self.name = LocalState.name
        self.profilePic = LocalState.profilePic
        self.biography = LocalState.biography
        self.role = UserRole(rawValue: LocalState.userRole) ?? .user
        self.isUserInfoFetched = true
    }
    
    private func persistNewProfile(forUser user: MongoUser) {
        LocalState.currentUserUid = user.userUid
        LocalState.username = user.username
        if let name = user.name { LocalState.name = name }
        if let profilePic = user.profilePic { LocalState.profilePic = profilePic }
        if let biography = user.biography { LocalState.biography = biography }
        LocalState.userRole = user.role ?? UserRole.user.rawValue
        LocalState.isUserInfoFetched = true

        // O socket conecta no lançamento do app, possivelmente antes de existir um uid.
        // Sem avisá-lo aqui, o `register` continuaria valendo para o usuário anterior (ou
        // para nenhum) e o recém-logado não receberia nenhum evento até reiniciar o app.
        SocketService.shared.handleUserSessionChanged()
    }
    
    private func getUserBanExpirationDate(token: String) async {
        let result = await AYServices.shared.getUserBanExpireDate(token: token)
        
        switch result {
        case .success(let expirationDate):
            signOut()
            overlayError = (true, ErrorMessage.getTempBannedErrorMessage(expirationDate: expirationDate.banExpirationDateTime))
        case .failure:
            signOut()
            overlayError = (true, ErrorMessage.getUserBanExpirarationDateErrorMessage)
        }
    }
    
    func isLoginInputValid() -> Bool {
        errorMessage = (nil, nil, nil)
        if emailInput.isEmpty { errorMessage.1 = "Please enter your email." }
        if passwordInput.isEmpty { errorMessage.2 = "Please enter your password." }
        let (_, b, c) = errorMessage
        return b == nil && c == nil ? true : false
    }
    
    func isSignupInputValid() -> Bool {
        errorMessage = (nil, nil, nil)
        if usernameInput.isEmpty { errorMessage.0 = "Please enter your username." }
        _ = isUsernameValid()
        if emailInput.isEmpty { errorMessage.1 = "Please enter your email." }
        if passwordInput.isEmpty { errorMessage.2 = "Please enter your password." }
        let (a, b, c) = errorMessage
        return a == nil && b == nil && c == nil ? true : false
    }
    
    func isUsernameValid() -> Bool {
        let regex = try! NSRegularExpression(pattern: "^[a-zA-Z0-9._]+$")
        let range = NSRange(location: 0, length: usernameInput.utf16.count)
        let isUserNameValid = regex.firstMatch(in: usernameInput, options: [], range: range) != nil
        if !isUserNameValid { errorMessage.0 = "Username can only contain letters, numbers, dots (.) and underscores (_), with no spaces or special characters." }
        return isUserNameValid
    }
    
    private func resetUserInfo() {
        print("🌎 resetUserInfo")
        username = ""
        name = nil
        profilePic = nil
        biography = nil
        showProfileInPublicationViews = true
        role = .user
        isUserInfoFetched = false
        isUserDiscoverable = false
        age = 18
        gender = .cisMale
        interestGenders = []
        minInterestAge = 25
        maxInterestAge = 40
        isDiscoverNotificationsEnabled = true
        
        forgetUserProfile()
    }
    
    private func forgetUserProfile() {
        LocalState.currentUserUid = ""
        LocalState.username = ""
        LocalState.name = ""
        LocalState.profilePic = ""
        LocalState.biography = ""
        LocalState.userRole = ""
        LocalState.isUserInfoFetched = false
        LocalState.isPostLocationVisible = false
        LocalState.agreedWithDiscoverDisclaimer = false

        // Derruba a conexão para que a sessão anterior deixe de receber eventos.
        SocketService.shared.handleUserSessionChanged()
    }
    
    private func resetInputs() {
        usernameInput = ""
        emailInput = ""
        passwordInput = ""
        flow = .login
        isLoading = false
        isForgotPasswordScreenDisplayed = false
        errorMessage = (nil, nil, nil)
    }
    
    private func getPreferredLanguage() -> String? {
        let preferredLanguages = Locale.preferredLanguages
        print("📚 Languages: \(preferredLanguages)")
        if let preferredLanguage = preferredLanguages.first {
            LocalState.preferredLanguage = preferredLanguage
            return preferredLanguage
        }
        return nil
    }
}
