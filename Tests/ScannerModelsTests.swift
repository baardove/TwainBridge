import XCTest
@testable import TwainBridge

final class ScannerModelsTests: XCTestCase {
    func testAutomaticSourcePrefersLoadedFeeder() {
        let capabilities = ScannerCapabilities(
            availableSources: [.flatbed, .documentFeeder],
            resolutions: [200, 300, 600],
            supportsDuplex: true,
            feederDocumentLoaded: true
        )

        XCTAssertEqual(capabilities.resolvedSource(for: .automatic), .documentFeeder)
    }

    func testAutomaticSourceFallsBackToFlatbed() {
        let capabilities = ScannerCapabilities(
            availableSources: [.flatbed, .documentFeeder],
            resolutions: [200, 300, 600],
            supportsDuplex: true,
            feederDocumentLoaded: false
        )

        XCTAssertEqual(capabilities.resolvedSource(for: .automatic), .flatbed)
    }

    func testExplicitUnsupportedSourceIsRejected() {
        let capabilities = ScannerCapabilities(
            availableSources: [.flatbed],
            resolutions: [300],
            supportsDuplex: false,
            feederDocumentLoaded: nil
        )

        XCTAssertNil(capabilities.resolvedSource(for: .documentFeeder))
    }

    func testSourceChoicesOnlyIncludeAutomaticForMultipleSources() {
        let oneSource = ScannerCapabilities(
            availableSources: [.flatbed],
            resolutions: [300],
            supportsDuplex: false,
            feederDocumentLoaded: nil
        )
        let twoSources = ScannerCapabilities(
            availableSources: [.flatbed, .documentFeeder],
            resolutions: [300],
            supportsDuplex: true,
            feederDocumentLoaded: nil
        )

        XCTAssertEqual(oneSource.sourceChoices, [.flatbed])
        XCTAssertEqual(twoSources.sourceChoices, [.automatic, .flatbed, .documentFeeder])
    }
}
