@preconcurrency import ImageCaptureCore
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
final class ScannerService: NSObject, ObservableObject {
    @Published private(set) var scanners: [ScannerSnapshot] = []
    @Published var selectedScannerID: String? = UserDefaults.standard.string(forKey: "scanner.defaultID") {
        didSet {
            if let selectedScannerID { UserDefaults.standard.set(selectedScannerID, forKey: "scanner.defaultID") }
            else { UserDefaults.standard.removeObject(forKey: "scanner.defaultID") }
        }
    }
    @Published private(set) var activity: ScannerActivity = .discovering
    @Published private(set) var scannedPageURLs: [URL] = []
    @Published private(set) var completedScanResult: CompletedScanResult?
    @Published private(set) var hardwareButtonRequestScannerID: String?

    private let browser = ICDeviceBrowser()
    private var devicesByID: [String: ICScannerDevice] = [:]
    private var pendingRequest: ScanRequest?
    private var activeScannerID: String?
    private var stagingDirectory: URL?
    private var resultWasPublished = false
    private var capabilityProbeSource: ScanSource?
    private var capabilityProbeScannerID: String?
    private var configurationSourceByDevice: [String: ScanSource] = [:]
    private var capabilityCacheByDevice: [String: [ScanSource: ScannerCapabilities]] = [:]
    private var recoveredStagingScans: [RecoveredStagingScan] = []

    override init() {
        super.init()
        browser.delegate = self
        browser.browsedDeviceTypeMask = .scanner
        browser.start()
        recoveredStagingScans = ScanStagingRecovery.recover()
        publishNextRecoveredStagingScan()
    }

    deinit {
        browser.stop()
    }

    var selectedScanner: ScannerSnapshot? {
        guard let selectedScannerID else { return scanners.first }
        return scanners.first { $0.id == selectedScannerID }
    }

    func refreshDiscovery() {
        browser.stop()
        activity = .discovering
        browser.start()
    }

    func startScan(_ request: ScanRequest) {
        guard !activity.isBusy else { return }
        guard completedScanResult == nil, recoveredStagingScans.isEmpty else { return }
        guard let device = devicesByID[request.scannerID],
              let snapshot = scanners.first(where: { $0.id == request.scannerID }) else {
            activity = .failed(.disconnected())
            return
        }
        guard let resolvedSource = snapshot.capabilities.resolvedSource(for: request.source) else {
            activity = .failed(.unsupportedSetting("The requested scan source is unavailable."))
            return
        }

        let effectiveRequest = ScanRequest(
            scannerID: request.scannerID,
            source: resolvedSource,
            colorMode: request.colorMode,
            resolution: request.resolution,
            duplex: request.duplex,
            pageSize: request.pageSize,
            orientation: request.orientation
        )
        do {
            guard hasMinimumStagingDiskHeadroom() else { throw DraftStoreError.insufficientDiskSpace }
            stagingDirectory = try ScanStagingRecovery.createDirectory(
                request: effectiveRequest,
                scannerName: snapshot.name
            )
        } catch {
            activity = .failed(.storage())
            return
        }

        scannedPageURLs = []
        resultWasPublished = false
        pendingRequest = effectiveRequest
        activeScannerID = request.scannerID
        configurationSourceByDevice[request.scannerID] = resolvedSource
        device.delegate = self

        if device.hasOpenSession {
            selectRequestedSource(on: device)
        } else {
            activity = .openingSession
            device.requestOpenSession()
        }
    }

    /// Selects an ICA functional unit without scanning so controls can reflect
    /// the feeder's or flatbed's own capabilities before acquisition starts.
    func prepareCapabilities(for source: ScanSource) {
        guard source != .automatic,
              !activity.isBusy,
              let scannerID = selectedScannerID,
              let device = devicesByID[scannerID],
              scanners.first(where: { $0.id == scannerID })?.capabilities.availableSources.contains(source) == true
        else { return }
        configurationSourceByDevice[scannerID] = source
        capabilityProbeSource = source
        capabilityProbeScannerID = scannerID
        device.delegate = self
        if device.hasOpenSession {
            selectCapabilityProbe(on: device)
        } else {
            activity = .openingSession
            device.requestOpenSession()
        }
    }

    func cancelScan() {
        guard let activeScannerID, let device = devicesByID[activeScannerID] else { return }
        device.cancelScan()
    }

    var hasUnsecuredCapturedPages: Bool {
        !scannedPageURLs.isEmpty && completedScanResult != nil
    }

    func prepareForTermination() {
        guard let activeScannerID, let device = devicesByID[activeScannerID] else { return }
        if !scannedPageURLs.isEmpty {
            publishCompletedResult(from: device, interrupted: true)
        }
        device.cancelScan()
    }

    func clearCompletedScan() {
        removeStagingDirectory()
        scannedPageURLs = []
        completedScanResult = nil
        if !publishNextRecoveredStagingScan() {
            activity = scanners.isEmpty ? .unavailable(String(localized: "No scanner found")) : .ready
        }
    }

    func acknowledgeCompletedScan() {
        removeStagingDirectory()
        scannedPageURLs = []
        completedScanResult = nil
        if !publishNextRecoveredStagingScan(), !activity.isBusy {
            activity = scanners.isEmpty ? .unavailable(String(localized: "No scanner found")) : .ready
        }
    }

    func retrySecuringCapturedPages() {
        guard let result = completedScanResult else { return }
        completedScanResult = nil
        completedScanResult = result
    }

    func reportDraftImportFailure(_ error: Error) {
        activity = .failed(.storage(pagesAlreadyScanned: true))
    }

    func acknowledgeHardwareButtonRequest() {
        hardwareButtonRequestScannerID = nil
    }

    private func selectRequestedSource(on device: ICScannerDevice) {
        guard let request = pendingRequest else { return }
        activity = .selectingSource
        let unitType: ICScannerFunctionalUnitType = request.source == .documentFeeder
            ? .documentFeeder
            : .flatbed
        device.requestSelect(unitType)
    }

    private func selectCapabilityProbe(on device: ICScannerDevice) {
        guard let source = capabilityProbeSource else { return }
        activity = .selectingSource
        device.requestSelect(source == .documentFeeder ? .documentFeeder : .flatbed)
    }

    private func configureAndScan(_ device: ICScannerDevice, unit: ICScannerFunctionalUnit) {
        guard let request = pendingRequest, let stagingDirectory else {
            finish(with: .unknown(), device: device)
            return
        }

        let supported = unit.supportedResolutions
        let resolution = nearestSupportedResolution(to: request.resolution, in: supported)
        unit.resolution = resolution
        unit.pixelDataType = switch request.colorMode {
        case .color: .RGB
        case .grayscale: .gray
        case .blackAndWhite: .BW
        }

        let duplexEnabled: Bool
        if let feeder = unit as? ICScannerFunctionalUnitDocumentFeeder {
            duplexEnabled = request.duplex && feeder.supportsDuplexScanning
            feeder.duplexScanningEnabled = duplexEnabled
        } else {
            duplexEnabled = false
        }

        guard configurePageSize(request.pageSize, on: unit) else {
            finish(with: .unsupportedSetting("That page size is not reported by this scan source."), device: device)
            return
        }
        configureOrientation(request.orientation, on: unit)

        var effectiveRequest = request
        effectiveRequest.resolution = resolution
        effectiveRequest.duplex = duplexEnabled
        pendingRequest = effectiveRequest
        do {
            try ScanStagingRecovery.updateRequest(in: stagingDirectory, request: effectiveRequest)
        } catch {
            finish(with: .storage(), device: device)
            return
        }

        device.transferMode = .fileBased
        device.downloadsDirectory = stagingDirectory
        device.documentName = "scan"
        device.documentUTI = UTType.tiff.identifier
        activity = .scanning(progress: 0)
        refreshSnapshot(for: device)
        device.requestScan()
    }

    private func nearestSupportedResolution(to requested: Int, in supported: IndexSet) -> Int {
        guard !supported.isEmpty else { return requested }
        return supported.min { abs($0 - requested) < abs($1 - requested) } ?? requested
    }

    private func hasMinimumStagingDiskHeadroom() -> Bool {
        do {
            try DiskCapacityGuard.verify(
                at: ScanStagingRecovery.defaultRootURL.deletingLastPathComponent(),
                requiredBytes: 0
            )
            return true
        } catch {
            return false
        }
    }

    private func removeStagingDirectory() {
        guard let stagingDirectory else { return }
        try? FileManager.default.removeItem(at: stagingDirectory)
        self.stagingDirectory = nil
    }

    @discardableResult
    private func publishNextRecoveredStagingScan() -> Bool {
        guard completedScanResult == nil, pendingRequest == nil, !recoveredStagingScans.isEmpty else {
            return false
        }
        let recovered = recoveredStagingScans.removeFirst()
        stagingDirectory = recovered.directory
        scannedPageURLs = recovered.result.pageURLs
        resultWasPublished = true
        completedScanResult = recovered.result
        activity = .completed(pageCount: recovered.result.pageURLs.count)
        return true
    }

    private func publishCompletedResult(from device: ICScannerDevice, interrupted: Bool) {
        guard !resultWasPublished, let request = pendingRequest, !scannedPageURLs.isEmpty else { return }
        resultWasPublished = true
        completedScanResult = CompletedScanResult(
            id: UUID(),
            pageURLs: scannedPageURLs,
            request: request,
            scannerName: device.name ?? String(localized: "Scanner"),
            completedAt: Date(),
            interrupted: interrupted
        )
    }

    private func finish(with failure: ScannerFailure, device: ICScannerDevice) {
        publishCompletedResult(from: device, interrupted: true)
        activity = .failed(failure)
        pendingRequest = nil
        capabilityProbeSource = nil
        capabilityProbeScannerID = nil
        activeScannerID = nil
        if device.hasOpenSession {
            device.requestCloseSession()
        }
    }

    private func configurePageSize(_ pageSize: ScanPageSize, on unit: ICScannerFunctionalUnit) -> Bool {
        guard let rawValue = pageSize.imageCaptureDocumentTypeRawValue else {
            // A driver may not expose ICScannerDocumentTypeDefault for a feeder.
            // Leaving its current value intact is the safest automatic behavior.
            return true
        }
        guard let documentType = ICScannerDocumentType(rawValue: UInt(rawValue)) else { return false }

        if let feeder = unit as? ICScannerFunctionalUnitDocumentFeeder {
            guard feeder.supportedDocumentTypes.contains(rawValue) else { return false }
            feeder.documentType = documentType
            return true
        }
        if let flatbed = unit as? ICScannerFunctionalUnitFlatbed {
            guard flatbed.supportedDocumentTypes.contains(rawValue) else { return false }
            flatbed.documentType = documentType
            return true
        }
        return false
    }

    private func configureOrientation(_ orientation: ScanOrientation, on unit: ICScannerFunctionalUnit) {
        guard orientation != .automatic else { return }
        let rawValue = orientation == .portrait ? 1 : 6
        guard let exifOrientation = ICEXIFOrientationType(rawValue: UInt(rawValue)) else { return }
        if let feeder = unit as? ICScannerFunctionalUnitDocumentFeeder {
            feeder.oddPageOrientation = exifOrientation
            feeder.evenPageOrientation = exifOrientation
        } else {
            unit.scanAreaOrientation = exifOrientation
        }
    }

    private func deviceID(for device: ICDevice) -> String {
        device.persistentIDString
            ?? device.uuidString
            ?? "\(device.name ?? String(localized: "Scanner"))-\(ObjectIdentifier(device).hashValue)"
    }

    private func connection(for device: ICDevice) -> ScannerConnection {
        if device.isRemote { return .shared }
        return switch device.transportType {
        case ICDeviceTransport.transportTypeUSB.rawValue: ScannerConnection.usb
        case ICDeviceTransport.transportTypeTCPIP.rawValue: ScannerConnection.network
        default: ScannerConnection.unknown
        }
    }

    private func refreshScannerList() {
        scanners = devicesByID.values
            .map(snapshot(for:))
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        if let selectedScannerID, !devicesByID.keys.contains(selectedScannerID) {
            self.selectedScannerID = nil
        }
        if selectedScannerID == nil {
            selectedScannerID = scanners.first?.id
        }
        switch activity {
        case .discovering, .ready, .unavailable, .completed:
            activity = scanners.isEmpty ? .unavailable(String(localized: "No scanner found")) : .ready
        default:
            break
        }
    }

    private func refreshSnapshot(for device: ICScannerDevice) {
        let id = deviceID(for: device)
        guard devicesByID[id] != nil else { return }
        refreshScannerList()
    }

    private func snapshot(for device: ICScannerDevice) -> ScannerSnapshot {
        var sources: Set<ScanSource> = []
        for number in device.availableFunctionalUnitTypes {
            if number.intValue == ICScannerFunctionalUnitType.flatbed.rawValue {
                sources.insert(.flatbed)
            } else if number.intValue == ICScannerFunctionalUnitType.documentFeeder.rawValue {
                sources.insert(.documentFeeder)
            }
        }

        let unit = device.selectedFunctionalUnit
        let id = deviceID(for: device)
        let currentSource: ScanSource? = if unit is ICScannerFunctionalUnitDocumentFeeder {
            .documentFeeder
        } else if unit is ICScannerFunctionalUnitFlatbed {
            .flatbed
        } else {
            nil
        }
        let liveCapabilities = capabilities(for: unit, availableSources: sources)
        if let currentSource {
            capabilityCacheByDevice[id, default: [:]][currentSource] = liveCapabilities
        }
        let configuredSource = configurationSourceByDevice[id]
        let capabilities = configuredSource.flatMap { capabilityCacheByDevice[id]?[$0] } ?? liveCapabilities

        return ScannerSnapshot(
            id: id,
            name: device.name ?? String(localized: "Scanner"),
            connection: connection(for: device),
            location: device.locationDescription ?? device.transportType ?? String(localized: "Unknown location"),
            capabilities: capabilities
        )
    }

    private func capabilities(
        for unit: ICScannerFunctionalUnit,
        availableSources sources: Set<ScanSource>
    ) -> ScannerCapabilities {
        let resolutions = Array(unit.supportedResolutions).filter { $0 > 0 }
        let reportedDocumentTypes: IndexSet? = if let feeder = unit as? ICScannerFunctionalUnitDocumentFeeder {
            feeder.supportedDocumentTypes
        } else if let flatbed = unit as? ICScannerFunctionalUnitFlatbed {
            flatbed.supportedDocumentTypes
        } else {
            nil
        }
        let pageSizes = [.automatic] + ScanPageSize.allCases.dropFirst().filter { pageSize in
            guard let rawValue = pageSize.imageCaptureDocumentTypeRawValue else { return false }
            return reportedDocumentTypes?.contains(rawValue) == true
        }
        let feeder = unit as? ICScannerFunctionalUnitDocumentFeeder
        return ScannerCapabilities(
            availableSources: sources,
            resolutions: resolutions.isEmpty ? [150, 200, 300, 600] : resolutions,
            pageSizes: pageSizes,
            // Some ICA drivers only expose feeder details after that unit is selected.
            // Keep the control available until the driver can give a definitive answer;
            // configureAndScan still enforces the device's actual capability.
            supportsDuplex: feeder?.supportsDuplexScanning ?? sources.contains(.documentFeeder),
            feederDocumentLoaded: feeder.map(\.documentLoaded)
        )
    }
}

extension ScannerService: @preconcurrency ICDeviceBrowserDelegate {
    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let scanner = device as? ICScannerDevice else { return }
        let id = deviceID(for: scanner)
        devicesByID[id] = scanner
        scanner.delegate = self
        refreshScannerList()
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        let id = deviceID(for: device)
        devicesByID.removeValue(forKey: id)
        capabilityCacheByDevice.removeValue(forKey: id)
        configurationSourceByDevice.removeValue(forKey: id)
        if activeScannerID == id {
            if let scanner = device as? ICScannerDevice {
                publishCompletedResult(from: scanner, interrupted: true)
            }
            pendingRequest = nil
            activeScannerID = nil
            activity = .failed(.disconnected())
        } else if capabilityProbeScannerID == id {
            capabilityProbeSource = nil
            capabilityProbeScannerID = nil
            activity = .failed(.disconnected())
        }
        refreshScannerList()
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, requestsSelect device: ICDevice) {
        guard device is ICScannerDevice else { return }
        hardwareButtonRequestScannerID = deviceID(for: device)
    }
}

extension ScannerService: @preconcurrency ICScannerDeviceDelegate {
    func device(_ device: ICDevice, didOpenSessionWithError error: (any Error)?) {
        guard let scanner = device as? ICScannerDevice else { return }
        if let error {
            finish(with: .classify(error), device: scanner)
            return
        }
        if pendingRequest != nil {
            selectRequestedSource(on: scanner)
        } else if capabilityProbeScannerID == deviceID(for: scanner), capabilityProbeSource != nil {
            selectCapabilityProbe(on: scanner)
        }
    }

    func device(_ device: ICDevice, didCloseSessionWithError error: (any Error)?) {
        if let error, !activity.isBusy {
            activity = .failed(.classify(error))
        }
    }

    func didRemove(_ device: ICDevice) {
        let id = deviceID(for: device)
        devicesByID.removeValue(forKey: id)
        capabilityCacheByDevice.removeValue(forKey: id)
        configurationSourceByDevice.removeValue(forKey: id)
        if capabilityProbeScannerID == id {
            capabilityProbeSource = nil
            capabilityProbeScannerID = nil
            activity = .failed(.disconnected())
        }
        refreshScannerList()
    }

    func scannerDevice(
        _ scanner: ICScannerDevice,
        didSelect functionalUnit: ICScannerFunctionalUnit,
        error: (any Error)?
    ) {
        if let error {
            finish(with: .classify(error), device: scanner)
            return
        }
        if pendingRequest == nil,
           capabilityProbeScannerID == deviceID(for: scanner),
           capabilityProbeSource != nil {
            let scannerID = deviceID(for: scanner)
            let sources = scanners.first(where: { $0.id == scannerID })?.capabilities.availableSources ?? []
            if let source = capabilityProbeSource {
                capabilityCacheByDevice[scannerID, default: [:]][source] = capabilities(
                    for: functionalUnit,
                    availableSources: sources
                )
                configurationSourceByDevice[scannerID] = source
            }
            capabilityProbeSource = nil
            capabilityProbeScannerID = nil
            activity = .ready
            refreshScannerList()
            if scanner.hasOpenSession { scanner.requestCloseSession() }
            return
        }
        configureAndScan(scanner, unit: functionalUnit)
    }

    func scannerDevice(_ scanner: ICScannerDevice, didScanTo url: URL) {
        scannedPageURLs.append(url)
        activity = .scanning(progress: Double(scannedPageURLs.count))
    }

    func scannerDevice(_ scanner: ICScannerDevice, didCompleteScanWithError error: (any Error)?) {
        if let error {
            finish(with: .classify(error), device: scanner)
            return
        }

        publishCompletedResult(from: scanner, interrupted: false)
        activity = .completed(pageCount: scannedPageURLs.count)
        pendingRequest = nil
        activeScannerID = nil
        refreshSnapshot(for: scanner)
        if scanner.hasOpenSession {
            scanner.requestCloseSession()
        }
    }
}
