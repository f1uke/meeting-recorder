import Foundation

/// Stub — full Core ML implementation lands in Task 6. Exists now so IdentityStore
/// can reference `SpeakerEmbedder.modelTag` as the on-disk schema invalidation tag.
actor SpeakerEmbedder {
    static let modelTag = "pyannote-v3-w8a16"
}
