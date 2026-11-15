import DeskhandCore
import Testing

@testable import DeskhandServer

@Suite struct ListenerConfigurationTests {
    @Test func buildsFromConfig() throws {
        let config = try DeskhandConfig(
            json: [
                "version": 1,
                "mac": "m1max2021",
                "listen": ["address": "10.0.0.96", "port": 8443],
                "service": ["names": ["deskhand-m1max2021.forge.svc"], "port": 443],
                "credentials": [
                    "client_subject": "CN=crew-executor,O=crew",
                    "ca_certificate_path": "/etc/deskhand/ca.pem",
                    "server_certificate_path": "/etc/deskhand/server.pem",
                    "server_key_path": "/etc/deskhand/server-key.pem",
                    "token_path": "/etc/deskhand/token",
                ],
                "allowance": ["path": "/var/run/birbhomes/allowance.json"],
            ]
        )
        let configuration = ListenerConfiguration(config: config)
        #expect(configuration.bindHost == "10.0.0.96")
        #expect(configuration.bindPort == 8443)
        #expect(configuration.hosts.accepts("deskhand-m1max2021.forge.svc:443"))
        #expect(configuration.clientCertificates.expectedSubject == "CN=crew-executor,O=crew")
        #expect(configuration.maxResponseBodyBytes == ContractConstants.maxResponseBodyBytes)
        #expect(ContractConstants.maxResponseBodyBytes == 5_400_000)
    }
}
