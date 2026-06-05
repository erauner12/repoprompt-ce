#if DEBUG
    import Foundation

    /// Debug-build-only in-memory secure storage used when local app signing cannot safely use Keychain.
    package final class EphemeralSecureKeyValueStore: SecureKeyValueStorageBackend {
        package static let shared = EphemeralSecureKeyValueStore()

        package let persistsValuesAcrossLaunches = false

        private var entries: [String: Data] = [:]
        private let lock = NSRecursiveLock()

        package init() {}

        package func save(
            _ value: String,
            for key: String,
            accessMode: SecureStorageAccessMode
        ) throws {
            guard let data = value.data(using: .utf8) else {
                throw SecureStorageError.invalidData
            }

            withLock {
                entries[key] = data
            }
        }

        package func get(
            for key: String,
            accessMode: SecureStorageAccessMode
        ) throws -> String {
            let data = try withLock {
                guard let data = entries[key] else {
                    throw SecureStorageError.itemNotFound
                }
                return data
            }
            guard let value = String(data: data, encoding: .utf8) else {
                throw SecureStorageError.invalidData
            }
            return value
        }

        package func delete(
            for key: String,
            accessMode: SecureStorageAccessMode
        ) throws {
            _ = withLock {
                entries.removeValue(forKey: key)
            }
        }

        private func withLock<T>(_ body: () throws -> T) rethrows -> T {
            lock.lock()
            defer { lock.unlock() }
            return try body()
        }
    }
#endif
