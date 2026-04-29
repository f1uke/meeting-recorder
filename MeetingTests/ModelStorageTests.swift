import XCTest
@testable import Meeting

final class ModelStorageTests: XCTestCase {
    func test_downloadBase_isInsideApplicationSupport() {
        let url = ModelStorage.downloadBase()
        let path = url.path(percentEncoded: false)
        XCTAssertTrue(
            path.contains("/Library/Application Support/"),
            "expected Application Support path, got: \(path)"
        )
        XCTAssertTrue(
            path.hasSuffix("/Models") || path.hasSuffix("/Models/"),
            "expected .../Models tail, got: \(path)"
        )
    }

    func test_downloadBase_isCreatedOnAccess() {
        let url = ModelStorage.downloadBase()
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: url.path(percentEncoded: false),
            isDirectory: &isDirectory
        )
        XCTAssertTrue(exists, "directory should be created")
        XCTAssertTrue(isDirectory.boolValue, "should be a directory, not a file")
    }

    func test_downloadBase_isStableAcrossCalls() {
        let a = ModelStorage.downloadBase()
        let b = ModelStorage.downloadBase()
        XCTAssertEqual(a, b)
    }

    func test_cacheSize_returnsNonNegative() {
        let size = ModelStorage.cacheSize()
        XCTAssertGreaterThanOrEqual(size, 0)
    }

    func test_downloadBase_avoidsDocumentsFolder() {
        // Documents is iCloud-synced by default — explicitly NOT where we
        // want 3+ GB of CoreML weights to live.
        let path = ModelStorage.downloadBase().path(percentEncoded: false)
        XCTAssertFalse(
            path.contains("/Documents/"),
            "models must not land in Documents (iCloud sync risk): \(path)"
        )
    }
}
