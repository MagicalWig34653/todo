import Foundation

/// One file a run writes: path relative to the base path of the target and its exact bytes.
struct DeployUploadFile: Sendable, Equatable { let path: String; let data: Data }
