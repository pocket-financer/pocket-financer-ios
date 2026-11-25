import Foundation
import SwiftData

enum AppDatabaseStartupFailureKind: String, Equatable, Sendable {
    case unrecognizedStoreModel = "store_model_unrecognized"
    case newerStoreVersion = "store_created_by_newer_version"
    case protectedDataUnavailable = "protected_data_unavailable"
    case fileProtectionFailed = "file_protection_failed"
    case storeOpenFailed = "store_open_failed"
}

enum AppDatabaseStartupPhase: Sendable {
    case openingStore
    case applyingFileProtection
}

struct AppDatabaseStartupFailure: Error, Equatable, Sendable {
    let kind: AppDatabaseStartupFailureKind
    let diagnosticCode: String

    init(kind: AppDatabaseStartupFailureKind, diagnosticCode: String) {
        self.kind = kind
        self.diagnosticCode = diagnosticCode
    }

    init(classifying error: Error, phase: AppDatabaseStartupPhase) {
        let errors = Self.errorChain(startingAt: error)

        if let modelError = errors.first(where: Self.isUnrecognizedModelError) {
            self.init(
                kind: .unrecognizedStoreModel,
                diagnosticCode: Self.safeDiagnosticCode(for: modelError)
            )
        } else if let newerStoreError = errors.first(where: Self.isNewerStoreError) {
            self.init(
                kind: .newerStoreVersion,
                diagnosticCode: Self.safeDiagnosticCode(for: newerStoreError)
            )
        } else if let protectionError = errors.first(where: Self.isProtectedDataError) {
            self.init(
                kind: .protectedDataUnavailable,
                diagnosticCode: Self.safeDiagnosticCode(for: protectionError)
            )
        } else {
            let fallbackError = errors.first ?? NSError(domain: NSCocoaErrorDomain, code: -1)
            let fallbackKind: AppDatabaseStartupFailureKind
            switch phase {
            case .openingStore:
                fallbackKind = .storeOpenFailed
            case .applyingFileProtection:
                fallbackKind = .fileProtectionFailed
            }
            self.init(
                kind: fallbackKind,
                diagnosticCode: Self.safeDiagnosticCode(for: fallbackError)
            )
        }
    }

    var safeCode: String {
        kind.rawValue
    }

    private static let unrecognizedModelCocoaCodes: Set<Int> = [
        134_000,  // NSPersistentStoreInvalidTypeError
        134_010,  // NSPersistentStoreTypeMismatchError
        134_100,  // NSPersistentStoreIncompatibleVersionHashError
        134_130,  // NSMigrationMissingSourceModelError
        134_140,  // NSMigrationMissingMappingModelError
        134_504,  // NSManagedObjectModelReferenceNotFoundError
        134_505,  // NSStagedMigrationFrameworkVersionMismatchError
    ]

    private static func errorChain(startingAt error: Error) -> [NSError] {
        var result: [NSError] = []
        var current: NSError? = error as NSError

        for _ in 0..<6 {
            guard let resolvedError = current else { break }
            result.append(resolvedError)
            current = resolvedError.userInfo[NSUnderlyingErrorKey] as? NSError
        }

        return result
    }

    private static func isUnrecognizedModelError(_ error: NSError) -> Bool {
        error.domain == NSCocoaErrorDomain && unrecognizedModelCocoaCodes.contains(error.code)
    }

    private static func isNewerStoreError(_ error: NSError) -> Bool {
        error.domain == NSCocoaErrorDomain && error.code == 134_506
    }

    private static func isProtectedDataError(_ error: NSError) -> Bool {
        if error.domain == NSCocoaErrorDomain {
            return error.code == NSFileReadNoPermissionError
                || error.code == NSFileWriteNoPermissionError
        }
        return error.domain == NSPOSIXErrorDomain && (error.code == 1 || error.code == 13)
    }

    private static func safeDiagnosticCode(for error: NSError) -> String {
        let safeDomain =
            switch error.domain {
            case NSCocoaErrorDomain:
                "NSCocoaErrorDomain"
            case NSPOSIXErrorDomain:
                "NSPOSIXErrorDomain"
            default:
                "StoreInitializationError"
            }
        return "\(safeDomain)/\(error.code)"
    }
}

@MainActor
final class AppDatabase {
    private final class SharedOpenAttempt {
        let task: Task<AppDatabase, Error>

        init() {
            task = Task.detached(priority: .userInitiated) {
                try AppDatabase()
            }
        }
    }

    private static var sharedInstance: AppDatabase?
    private static var sharedOpenAttempt: SharedOpenAttempt?

    let container: ModelContainer
    let storeURL: URL?

    static func openShared() async throws -> AppDatabase {
        if let sharedInstance {
            return sharedInstance
        }

        let attempt: SharedOpenAttempt
        if let sharedOpenAttempt {
            attempt = sharedOpenAttempt
        } else {
            attempt = SharedOpenAttempt()
            sharedOpenAttempt = attempt
        }

        do {
            let database = try await attempt.task.value
            try await database.prepareForProcessing()
            if let sharedInstance {
                if sharedOpenAttempt === attempt {
                    sharedOpenAttempt = nil
                }
                return sharedInstance
            }
            sharedInstance = database
            if sharedOpenAttempt === attempt {
                sharedOpenAttempt = nil
            }
            return database
        } catch {
            if sharedOpenAttempt === attempt {
                sharedOpenAttempt = nil
            }
            throw error
        }
    }

    nonisolated init(inMemory: Bool = false, storeURL explicitStoreURL: URL? = nil) throws {
        let schema = Schema(versionedSchema: PocketFinancerSchemaV7.self)

        if inMemory {
            let configuration = ModelConfiguration(
                "PocketFinancerTests",
                schema: schema,
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )
            do {
                container = try ModelContainer(
                    for: schema,
                    migrationPlan: PocketFinancerMigrationPlan.self,
                    configurations: configuration
                )
                storeURL = nil
            } catch {
                throw AppDatabaseStartupFailure(classifying: error, phase: .openingStore)
            }
            return
        }

        let databaseURL: URL
        do {
            if let explicitStoreURL {
                databaseURL = explicitStoreURL
            } else {
                let baseURL = try FileManager.default.url(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: true
                )
                databaseURL =
                    baseURL
                    .appending(path: "PocketFinancer", directoryHint: .isDirectory)
                    .appending(path: "PocketFinancer.store")
            }

            try SecureStoreFilePolicy.prepareDirectory(databaseURL.deletingLastPathComponent())
        } catch {
            throw AppDatabaseStartupFailure(classifying: error, phase: .applyingFileProtection)
        }

        let configuration = ModelConfiguration(
            "PocketFinancer",
            schema: schema,
            url: databaseURL,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        let openedContainer: ModelContainer
        do {
            openedContainer = try ModelContainer(
                for: schema,
                migrationPlan: PocketFinancerMigrationPlan.self,
                configurations: configuration
            )
        } catch {
            throw AppDatabaseStartupFailure(classifying: error, phase: .openingStore)
        }

        do {
            try SecureStoreFilePolicy.applyToStoreFiles(at: databaseURL)
        } catch {
            throw AppDatabaseStartupFailure(classifying: error, phase: .applyingFileProtection)
        }

        container = openedContainer
        storeURL = databaseURL
    }

    func refreshFileProtection() throws {
        guard let storeURL else { return }
        do {
            try SecureStoreFilePolicy.applyToStoreFiles(at: storeURL)
        } catch {
            throw AppDatabaseStartupFailure(classifying: error, phase: .applyingFileProtection)
        }
    }

    func prepareForProcessing() async throws {
        let store = SmsProcessingStore(modelContainer: container)
        try await store.backfillLegacyTransactions()
        try await store.recoverExpiredOperations()
    }
}
