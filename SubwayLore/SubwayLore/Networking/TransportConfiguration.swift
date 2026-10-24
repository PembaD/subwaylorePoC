import Foundation
import Network
import Security

enum TransportConfiguration {
    static let applicationProtocol = "subwaylore-poc-v1"

    static func parameters() throws -> NWParametersBuilder<TLS> {
        let material = try POCTLSIdentity.load()
        let tls = TLS {
            TCP()
        }
        .localIdentity(material.identity)
        .peerAuthentication(.required)
        .applicationProtocols([applicationProtocol])
        .certificateValidator { _, trust in
            POCTLSIdentity.isPinned(trust: trust, certificateData: material.certificateData)
        }

        return NWParametersBuilder.parameters {
            tls
        }
        .peerToPeerIncluded(true)
    }
}

private struct POCTLSIdentity: @unchecked Sendable {
    static let resourceName = "subwaylore-poc"
    static let password = "subwaylore-poc-only"

    let identity: sec_identity_t
    let certificateData: Data

    static func load(bundle: Bundle = .main) throws -> POCTLSIdentity {
        guard let url = bundle.url(forResource: resourceName, withExtension: "p12") else {
            throw TransportConfigurationError.missingIdentity
        }

        let data = try Data(contentsOf: url)
        var importedItems: CFArray?
        let options = [kSecImportExportPassphrase as String: password] as CFDictionary
        let status = SecPKCS12Import(data as CFData, options, &importedItems)
        guard status == errSecSuccess,
              let item = (importedItems as? [[String: Any]])?.first,
              let secIdentity = item[kSecImportItemIdentity as String] as! SecIdentity?,
              let identity = sec_identity_create(secIdentity) else {
            throw TransportConfigurationError.invalidIdentity(status)
        }

        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(secIdentity, &certificate) == errSecSuccess,
              let certificate else {
            throw TransportConfigurationError.missingCertificate
        }

        return POCTLSIdentity(
            identity: identity,
            certificateData: SecCertificateCopyData(certificate) as Data
        )
    }

    static func isPinned(trust: sec_trust_t, certificateData: Data) -> Bool {
        let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
        guard let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate],
              let leaf = chain.first else {
            return false
        }
        return SecCertificateCopyData(leaf) as Data == certificateData
    }
}

enum TransportConfigurationError: Error, Equatable {
    case missingIdentity
    case invalidIdentity(OSStatus)
    case missingCertificate
}
