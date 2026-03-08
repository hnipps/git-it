import XCTest
@testable import LogseqGit

final class KeychainServiceTests: XCTestCase {

    private let service = KeychainService.shared

    func testValidateEd25519Key() {
        let key = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAA=
        -----END OPENSSH PRIVATE KEY-----
        """
        let result = service.validateSSHKey(key.data(using: .utf8)!)
        XCTAssertEqual(result, .ed25519)
    }

    func testValidateECDSAKey() {
        let key = """
        -----BEGIN EC PRIVATE KEY-----
        MHQCAQEEIBkg4LVWM9nuwNSk3yByxZpYRTBnVJk=
        -----END EC PRIVATE KEY-----
        """
        let result = service.validateSSHKey(key.data(using: .utf8)!)
        XCTAssertEqual(result, .ecdsa)
    }

    func testValidateRSAKey() {
        let key = """
        -----BEGIN RSA PRIVATE KEY-----
        MIIEowIBAAKCAQEA0Z3VS5JJcds3xfn/ygWep4PAtGoRBh8gU=
        -----END RSA PRIVATE KEY-----
        """
        let result = service.validateSSHKey(key.data(using: .utf8)!)
        XCTAssertEqual(result, .rsa)
    }

    func testValidateGenericPKCS8Key() {
        let key = """
        -----BEGIN PRIVATE KEY-----
        MIIEvQIBADANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCg==
        -----END PRIVATE KEY-----
        """
        let result = service.validateSSHKey(key.data(using: .utf8)!)
        XCTAssertEqual(result, .rsa)
    }

    func testValidateInvalidKeyReturnsNil() {
        let garbage = "this is not a key at all"
        let result = service.validateSSHKey(garbage.data(using: .utf8)!)
        XCTAssertNil(result)
    }

    func testValidateNonUTF8DataReturnsNil() {
        let bytes: [UInt8] = [0xFF, 0xFE, 0x00, 0x01, 0x80, 0x81]
        let data = Data(bytes)
        XCTAssertNil(service.validateSSHKey(data))
    }
}
