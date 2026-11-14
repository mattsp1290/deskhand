#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// What `lstat` says about a path, compared between polls to notice that a credential file was
/// rewritten, replaced by rename, removed or had its mode changed. Nil for a path that cannot be
/// stat-ed, so a file appearing or disappearing is a change too.
///
/// Credential files are watched by polling on both macOS and Linux. A kqueue or inotify watch is
/// bound to one inode and is lost when a rotation renames a new file into place, so it would need
/// a directory watch and re-arming per platform; four `lstat` calls a second cost nothing and
/// behave the same everywhere.
struct FileSignature: Hashable, Sendable {
    let device: UInt64
    let inode: UInt64
    let mode: UInt32
    let owner: UInt32
    let size: Int64
    let modified: Int64
    let modifiedNanoseconds: Int64
    let changed: Int64
    let changedNanoseconds: Int64

    static func of(path: String) -> FileSignature? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        #if canImport(Darwin)
            let modified = info.st_mtimespec
            let changed = info.st_ctimespec
        #else
            let modified = info.st_mtim
            let changed = info.st_ctim
        #endif
        return FileSignature(
            device: UInt64(truncatingIfNeeded: info.st_dev),
            inode: UInt64(truncatingIfNeeded: info.st_ino),
            mode: UInt32(truncatingIfNeeded: info.st_mode),
            owner: UInt32(truncatingIfNeeded: info.st_uid),
            size: Int64(truncatingIfNeeded: info.st_size),
            modified: Int64(truncatingIfNeeded: modified.tv_sec),
            modifiedNanoseconds: Int64(truncatingIfNeeded: modified.tv_nsec),
            changed: Int64(truncatingIfNeeded: changed.tv_sec),
            changedNanoseconds: Int64(truncatingIfNeeded: changed.tv_nsec)
        )
    }
}
