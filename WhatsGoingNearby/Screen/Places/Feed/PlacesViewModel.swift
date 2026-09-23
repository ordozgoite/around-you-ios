//
//  FeedViewModel.swift
//  WhatsGoingNearby
//
//  Created by Victor Ordozgoite on 13/02/24.
//

import Foundation
import SwiftUI

@MainActor
class PlacesViewModel: ObservableObject {
    
    @Published var posts: [FormattedPost] = []
    @Published var isLoading: Bool = false
    @Published var isCommentScreenPresented = false
    @Published var overlayError: (Bool, LocalizedStringKey) = (false, "")
    @Published var initialPostsFetched: Bool = false
    @Published var feedTimer: Timer?
    @Published var shouldUpdateFeed: Bool = true
    @Published var isLostAndFoundScreenDisplayed: Bool = false
    @Published var isReportScreenDisplayed: Bool = false
    @Published var isHelpViewDisplayed: Bool = false
    @Published var postToBePublished: PendingPost? = nil
    @Published private(set) var publicationCreationEligibility: PublicationCreationEligibility? = nil
    
    private var createPostTask: Task<Void, Never>?
    private var publicationEligibilityUpdatedAt: Date? = nil

    func resetSession() {
        let temporaryVideoURL = postToBePublished?.video?.url
        createPostTask?.cancel()
        createPostTask = nil
        feedTimer?.invalidate()
        feedTimer = nil
        removeTemporaryVideo(at: temporaryVideoURL)

        posts = []
        isLoading = false
        isCommentScreenPresented = false
        overlayError = (false, "")
        initialPostsFetched = false
        shouldUpdateFeed = true
        isLostAndFoundScreenDisplayed = false
        isReportScreenDisplayed = false
        isHelpViewDisplayed = false
        postToBePublished = nil
        invalidatePublicationCreationEligibility()
    }

    var isPublicationEligibilityFresh: Bool {
        guard let publicationEligibilityUpdatedAt else { return false }
        return Date().timeIntervalSince(publicationEligibilityUpdatedAt) < 60
    }

    var isPublicationLimitReached: Bool {
        publicationCreationEligibility?.isLimitReached == true
    }

    var publicationLimitMessage: String {
        guard let eligibility = publicationCreationEligibility else {
            return "You’ve reached the maximum number of active publications allowed."
        }

        let limitDescription = "You have \(eligibility.activeCount) of \(eligibility.publicationLimit) active publications."
        guard let expirationDate = eligibility.expirationDate else {
            return "\(limitDescription) Finish an active publication before creating another one."
        }

        return "\(limitDescription) You can publish again after \(expirationDate.formatted(date: .abbreviated, time: .shortened))."
    }
    
    func getPosts(location: Location, token: String) async {
        if !initialPostsFetched { isLoading = true }
        defer { isLoading = false }
        let result = await AYServices.shared.getAllPublicationsNearBy(latitude: location.latitude, longitude: location.longitude, token: token)
        switch result {
        case .success(let posts):
            updatePosts(with: posts)
        case .failure:
            if !initialPostsFetched {
                overlayError = (true, ErrorMessage.getPostsErrorMessage)
            }
        }
        initialPostsFetched = true
    }

    @discardableResult
    func refreshPublicationCreationEligibility(token: String) async -> PublicationCreationEligibility? {
        let result = await AYServices.shared.getPublicationCreationEligibility(token: token)
        guard case .success(let eligibility) = result else { return nil }

        publicationCreationEligibility = eligibility
        publicationEligibilityUpdatedAt = Date()
        return eligibility
    }

    func invalidatePublicationCreationEligibility() {
        publicationCreationEligibility = nil
        publicationEligibilityUpdatedAt = nil
    }

    func finishActivePublicationForReplacement(publicationId: String, token: String) async -> Bool {
        let result = await AYServices.shared.finishPublication(publicationId: publicationId, token: token)
        guard case .success = result else { return false }

        finishPost(withId: publicationId)
        _ = await refreshPublicationCreationEligibility(token: token)
        return true
    }
    
    func startCreatingPendingPost(
        latitude: Double,
        longitude: Double,
        token: String
    ) {
        guard createPostTask == nil else { return }
        guard postToBePublished != nil else { return }

        createPostTask = Task {
            do {
                try await createNewPost(
                    latitude: latitude,
                    longitude: longitude,
                    token: token
                )
            } catch is CancellationError {
                print("🚫 Pending post creation cancelled.")
            } catch {
                switch postToBePublished?.status {
                case .failed:
                    break
                default:
                    postToBePublished?.status = .failed(message: "Erro ao publicar")
                }
            }

            createPostTask = nil
        }
    }

    func cancelCreatingPendingPost() {
        let temporaryVideoURL = postToBePublished?.video?.url
        createPostTask?.cancel()
        createPostTask = nil

        postToBePublished = nil
        removeTemporaryVideo(at: temporaryVideoURL)

        refreshFeed()
    }
    
    private func createNewPost(latitude: Double, longitude: Double, token: String) async throws {
        try Task.checkCancellation()

        postToBePublished?.progress = 0.05
        postToBePublished?.status = .queued

        guard let post = postToBePublished else { return }

        var imageUrl: String? = nil
        var videoUrl: String? = nil
        var videoThumbnailUrl: String? = nil

        if let video = post.video {
            try Task.checkCancellation()

            postToBePublished?.progress = 0.2
            postToBePublished?.status = .uploadingVideo

            do {
                let urls = try await FirebaseService.shared.storeVideoAndThumbnail(
                    videoURL: video.url,
                    thumbnail: video.thumbnail
                )
                videoUrl = urls.videoUrl
                videoThumbnailUrl = urls.thumbnailUrl
            } catch {
                postToBePublished?.status = .failed(message: "Erro ao enviar vídeo")
                throw error
            }

            try Task.checkCancellation()
        } else if let img = post.image {
            try Task.checkCancellation()

            postToBePublished?.progress = 0.2
            postToBePublished?.status = .uploadingImage

            do {
                imageUrl = try await FirebaseService.shared.storeImageAndGetUrl(img)
            } catch {
                postToBePublished?.status = .failed(message: "Erro ao enviar imagem")
                throw error
            }

            try Task.checkCancellation()
        }

        postToBePublished?.progress = 0.7
        postToBePublished?.status = .creatingPost

        try Task.checkCancellation()

        let result = await AYServices.shared.postNewPublication(
            text: post.text.nonEmptyOrNil(),
            tag: post.tag.rawValue,
            imageUrl: imageUrl,
            videoUrl: videoUrl,
            videoThumbnailUrl: videoThumbnailUrl,
            latitude: latitude,
            longitude: longitude,
            isLocationVisible: post.isLocationVisible,
            token: token
        )

        try Task.checkCancellation()

        try await handleCreateNewPostResult(result, token: token)
    }
    
    private func handleCreateNewPostResult(_ result: Result<Post, RequestError>, token: String) async throws {
        switch result {
        case .success:
            print("✅ Post successfully created.")
            publicationCreationEligibility = nil
            publicationEligibilityUpdatedAt = nil
            removeTemporaryVideo(at: postToBePublished?.video?.url)
            postToBePublished?.progress = 1
            postToBePublished?.status = .completed
            refreshFeed()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.postToBePublished = nil
            }
        case .failure(let error):
            if error == .forbidden {
                _ = await refreshPublicationCreationEligibility(token: token)
                postToBePublished?.progress = 0
                postToBePublished?.status = .limitReached
            } else {
                postToBePublished?.progress = 0
                postToBePublished?.status = .failed(message: "Erro ao publicar")
            }
            throw error
        }
    }
    
    private func refreshFeed() {
        NotificationCenter.default.post(name: .refreshLocationSensitiveData, object: nil)
    }
    
    private func updatePosts(with posts: [FormattedPost]) {
        if shouldUpdateFeed {
            self.posts = posts
        }
    }
    
    func deletePost(postId: String, token: String) async {
        isLoading = true
        defer { isLoading = false }
        let result = await AYServices.shared.deletePublication(publicationId: postId, token: token)
        handlePostDeletionResult(withId: postId, result)
    }
    
    private func handlePostDeletionResult(withId postId: String, _ result: Result<DeletePublicationResponse, RequestError>) {
        switch result {
        case .success:
            invalidatePublicationCreationEligibility()
            removePost(withId: postId)
        case .failure:
            overlayError = (true, ErrorMessage.deletePostErrorMessage)
        }
    }
    
    func removePost(withId postId: String) {
        posts.removeAll { $0.id == postId }
    }
    
    func likePost(withId postId: String) {
        if let index = posts.firstIndex(where: { $0.id == postId }),
           posts[index].likes != nil,
           posts[index].didLike != nil {
            posts[index].likes! += 1
            posts[index].didLike = true
        }
    }
    
    func unlikePost(withId postId: String) {
        if let index = posts.firstIndex(where: { $0.id == postId }),
           posts[index].likes != nil,
           posts[index].didLike != nil {
            posts[index].likes! -= 1
            posts[index].didLike = false
        }
    }
    
    func finishPost(withId postId: String) {
        if let index = posts.firstIndex(where: { $0.id == postId }) {
            posts[index].isFinished = true
        }
        publicationCreationEligibility = nil
        publicationEligibilityUpdatedAt = nil
    }
    
    func followPost(withId postId: String) {
        if let index = posts.firstIndex(where: { $0.id == postId }) {
            posts[index].isSubscribed = true
        }
    }
    
    func unfollowPost(withId postId: String) {
        if let index = posts.firstIndex(where: { $0.id == postId }) {
            posts[index].isSubscribed = false
        }
    }
    
    private func removeTemporaryVideo(at url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
