import Vapor

/// The single place where the command center obtains the attachment service. Attachment internals (storage
/// backend) belong to the attachment module; this adapter only needs `begin`, `upload`, `complete`, `abort`.
enum CommandCenterAttachments {
    static func service(settings: AppSettings) -> AttachmentService {
        AttachmentService(settings: settings)
    }
}
