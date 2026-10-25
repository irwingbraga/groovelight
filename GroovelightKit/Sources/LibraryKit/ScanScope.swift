/// What part of a library folder a scan looks at.
public enum ScanScope: Sendable, Equatable {
    /// Every file of the folder.
    case full
    /// Only these folders (and what is below them). Songs in `artworkFolders` are read again even if their files did not
    /// change, because a cover image beside them did.
    case folders(Set<String>, artworkFolders: Set<String> = [])
}
