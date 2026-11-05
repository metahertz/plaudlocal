import XCTest
@testable import PlaudLocal

final class FileDecryptorTests: XCTestCase {
    func test_badMagic_throws() {
        let junk = Data("NOTPLAUD".utf8) + Data(count: 512)
        XCTAssertThrowsError(try FileDecryptor.decrypt(fileData: junk, privateKeyPEM: "unused")) { error in
            guard case FileDecryptorError.badMagic = error else {
                return XCTFail("expected badMagic, got \(error)")
            }
        }
    }

    func test_version2_rejected() {
        var data = Data("PLAUD.AI".utf8)
        data.append(contentsOf: withUnsafeBytes(of: UInt16(2).littleEndian) { Data($0) }) // version
        data.append(contentsOf: withUnsafeBytes(of: UInt16(512).littleEndian) { Data($0) }) // header size
        data.append(Data(count: 512 - data.count))
        XCTAssertThrowsError(try FileDecryptor.decrypt(fileData: data, privateKeyPEM: "unused")) { error in
            guard case FileDecryptorError.unsupportedVersion(2) = error else {
                return XCTFail("expected unsupportedVersion(2), got \(error)")
            }
        }
    }
}
