import XCTest
import OpenBatteryCore

/// Synthetic inputs exercise the same pure routing plan used by HIDProvider.
/// Descriptor eligibility belongs to the caller; these are already qualified channels.
final class MXBluetoothRoutingTests: XCTestCase {
    func testBluetoothLowEnergyRoutesExactlyOneDirectTargetWithCanonicalChannelOneID() {
        let targets = HIDRoutingPlan.targets(
            transport: "Bluetooth Low Energy",
            channelIdentity: "test-channel-1"
        )

        XCTAssertEqual(targets, [
            HIDRoutingTarget(wireAddress: 255, logicalID: "test-channel-1-1")
        ], "Direct BLE must query only 255 and append canonical -1 to the entire opaque channel identity.")
    }

    func testBluetoothRoutesExactlyOneDirectTargetWithCanonicalChannelOneID() {
        let targets = HIDRoutingPlan.targets(
            transport: "Bluetooth",
            channelIdentity: "test-channel"
        )

        XCTAssertEqual(targets, [
            HIDRoutingTarget(wireAddress: 255, logicalID: "test-channel-1")
        ], "A qualified Bluetooth channel must query only 255 while retaining its old channel-1 identity.")
    }

    func testUSBPreservesAllSixOrderedWireAndLogicalIDPairsWithoutDirectAddress() {
        let targets = HIDRoutingPlan.targets(
            transport: "USB",
            channelIdentity: "test-receiver"
        )

        XCTAssertEqual(targets, [
            HIDRoutingTarget(wireAddress: 1, logicalID: "test-receiver-1"),
            HIDRoutingTarget(wireAddress: 2, logicalID: "test-receiver-2"),
            HIDRoutingTarget(wireAddress: 3, logicalID: "test-receiver-3"),
            HIDRoutingTarget(wireAddress: 4, logicalID: "test-receiver-4"),
            HIDRoutingTarget(wireAddress: 5, logicalID: "test-receiver-5"),
            HIDRoutingTarget(wireAddress: 6, logicalID: "test-receiver-6")
        ])
        XCTAssertFalse(targets.contains { $0.wireAddress == 255 })
    }

    func testOnlyExactBluetoothTransportStringsEnterDirectRouting() {
        // Negative strings are deliberate mutations of the two specified labels,
        // not invented transport aliases. Unknown strings retain the legacy plan.
        let nonmatchingTransports = [
            "", "bluetooth", "BLUETOOTH", " Bluetooth", "Bluetooth ",
            "Bluetooth\n", "Bluetooth Low Energy ", " Bluetooth Low Energy",
            "bluetooth low energy", "Bluetooth Low Energy-extra",
            "prefix-Bluetooth", "USB Bluetooth Low Energy"
        ]

        for transport in nonmatchingTransports {
            XCTAssertEqual(
                HIDRoutingPlan.targets(transport: transport, channelIdentity: "test-channel"),
                receiverTargets(channelIdentity: "test-channel"),
                "Transport must match exactly: \(String(reflecting: transport))"
            )
        }
    }

    func testUSBPreservesOpaqueIdentityNamespaceEvenWhenItContainsTransportLabels() {
        let identities = [
            "test-channel", "test-channel-1", "Test-channel", "test-channel ",
            "test/channel", "Bluetooth", "Bluetooth Low Energy", "USB"
        ]

        for identity in identities {
            XCTAssertEqual(
                HIDRoutingPlan.targets(transport: "USB", channelIdentity: identity),
                receiverTargets(channelIdentity: identity),
                "Channel identity is opaque and cannot select transport routing: \(String(reflecting: identity))"
            )
        }
    }

    func testUnrelatedOpaqueChannelsKeepDisjointLogicalIDsForEachSupportedTransport() {
        let identities = ["test-channel", "test-channel-1", "Test-channel", "test-channel "]

        for transport in ["Bluetooth Low Energy", "Bluetooth", "USB"] {
            var previousIDs = Set<String>()
            for identity in identities {
                let targets = HIDRoutingPlan.targets(transport: transport, channelIdentity: identity)
                let ids = Set(targets.map(\.logicalID))
                XCTAssertFalse(ids.isEmpty, "Channel must have a routing target: \(transport), \(identity)")
                XCTAssertEqual(ids.count, targets.count, "Targets cannot duplicate a logical ID.")
                XCTAssertTrue(
                    previousIDs.isDisjoint(with: ids),
                    "Distinct opaque channel namespaces must not merge: \(transport), \(String(reflecting: identity))"
                )
                previousIDs.formUnion(ids)
            }
        }
    }

    private func receiverTargets(channelIdentity: String) -> [HIDRoutingTarget] {
        [1, 2, 3, 4, 5, 6].map { address in
            HIDRoutingTarget(wireAddress: UInt8(address), logicalID: channelIdentity + "-\(address)")
        }
    }
}
