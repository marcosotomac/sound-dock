import CoreAudio
import Dispatch

/// Owns a Core Audio property listener and removes it when released.
final class PropertyListener {
    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let queue: DispatchQueue
    private let block: AudioObjectPropertyListenerBlock

    /// Returns `nil` when the object does not have the property or the listener cannot be installed.
    init?(object: AudioObjectID, address: AudioObjectPropertyAddress, queue: DispatchQueue, handler: @escaping () -> Void) {
        guard AudioObjectIO.has(object, address) else { return nil }
        self.object = object
        self.address = address
        self.queue = queue
        self.block = { _, _ in handler() }
        guard AudioObjectAddPropertyListenerBlock(object, &self.address, queue, block) == noErr else { return nil }
    }

    deinit {
        // Fails harmlessly when the object is already gone.
        AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
    }
}
