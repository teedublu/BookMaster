import SwiftUI
import AppKit

/// Phase 1 app shell: reproduces every field/control from
/// src/ui/main_window.py's create_widgets(), backed by real Codable
/// settings persistence, but with NO disk/encoding/USB logic wired in
/// yet (that's Phase 2 onward). Buttons that would trigger real work in
/// the Python app just log a "(stub)" line here.
struct ContentView: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var usbMonitor: USBMonitor
    @StateObject private var log = LogStore()
    @StateObject private var camera = CameraScanner()
    @State private var selectedDriveID: String?
    @State private var loggedDriveIDs: Set<String> = []
    @State private var isBuilding = false
    @State private var verificationResult: VerificationResult?
    @State private var isVerifying = false
    @State private var productionStats: ProductionStats?
    @State private var blockHistory: DeviceHistory?
    @State private var selectedTab: AppTab = .create
    @State private var metadataMode: MetadataMode = .single
    @State private var isBatchRunning = false
    @State private var batchSummary: (success: Int, failed: Int)?
    @StateObject private var productionLogStore = ProductionLogStore()

    private var productionLog: ProductionLog? { productionLogStore.log }

    /// Settings.databasePath's containing folder if set (a mounted
    /// network share, so production history follows one person across
    /// machines/locations), else the local per-machine default.
    private func resolvedDatabaseDirectory() -> URL {
        let trimmed = settingsStore.settings.databasePath.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return AppDatabase.defaultPath().deletingLastPathComponent()
        }
        return URL(fileURLWithPath: trimmed, isDirectory: true)
    }

    private let availableTests = ["Silence", "Loudness", "Metadata", "Frames", "Speed"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            tabBar
            Group {
                switch selectedTab {
                case .create: createMasterTab
                case .verify: verifyMasterTab
                }
            }
            logSection
                .padding([.horizontal, .bottom], 16)
        }
        .onAppear {
            log.append("Loaded settings from \(settingsStore.settingsFilePath)")
            log.append("Config: bit_rate=\(ConfigStore.shared.encoding.bitRate) max_drive_size=\(ConfigStore.shared.maxDriveSize)")
            if selectedDriveID == nil, let first = usbMonitor.drives.first {
                selectedDriveID = first.id
            }
            productionLogStore.open(inDirectory: resolvedDatabaseDirectory())
        }
        .onChange(of: settingsStore.settings.databasePath) { _ in
            productionLogStore.open(inDirectory: resolvedDatabaseDirectory())
            if let error = productionLogStore.lastError {
                log.append("Could not open production database at new location: \(error)")
            } else if let path = productionLogStore.currentPath {
                log.append("Production database: \(path.path)")
            }
        }
        .onChange(of: settingsStore.settings) { _ in
            settingsStore.save()
        }
        .onChange(of: usbMonitor.drives) { newDrives in
            let currentIDs = Set(newDrives.map(\.id))
            for drive in newDrives where !loggedDriveIDs.contains(drive.id) {
                log.append("USB candidate appeared: \(drive.bsdName) (\(drive.volumeName ?? "unmounted"), \(ByteCountFormatter.string(fromByteCount: drive.sizeBytes, countStyle: .file)))")
                announceHistory(for: drive)
            }
            for id in loggedDriveIDs where !currentIDs.contains(id) {
                log.append("USB candidate removed: \(id)")
            }
            loggedDriveIDs = currentIDs
            if let selectedDriveID, !currentIDs.contains(selectedDriveID) {
                self.selectedDriveID = nil
            }
            // Autoselect rather than making the user click a row first --
            // with only one candidate list (this app only ever writes to
            // exactly the kind of device that shows up here), the first
            // one in bsdName order is as good a default as any.
            if selectedDriveID == nil, let first = newDrives.first {
                selectedDriveID = first.id
            }
        }
        .onChange(of: settingsStore.settings.useWebcam) { enabled in
            if enabled {
                log.append("Requesting camera access\u{2026}")
                camera.start()
            } else {
                camera.stop()
            }
        }
        .onChange(of: camera.lastDetectedISBN) { isbn in
            guard let isbn else { return }
            settingsStore.settings.isbn = isbn
            log.append("Webcam detected ISBN \(isbn)")
        }
        .onChange(of: camera.errorMessage) { error in
            if let error { log.append("Camera error: \(error)") }
        }
        .onChange(of: settingsStore.settings.isbn) { isbn in
            lookupISBNIfEnabled(isbn)
        }
        .onChange(of: selectedDriveID) { _ in
            verificationResult = nil
            blockHistory = lookUpHistory(for: selectedDrive)
        }
    }

    // MARK: Create Master / Verify Master tabs
    //
    // Splits the single Python window into the two sides the app
    // actually has: authoring a new master image (left of the old
    // layout) versus inspecting/verifying a connected drive (right of
    // it). The log stays shared and visible under both tabs since both
    // sides write to it.
    //
    // A custom tab bar, not native TabView chrome: macOS's default top
    // tab strip is a small, low-contrast row of icon+label buttons that
    // reads as secondary UI. These two tabs ARE the app's primary
    // navigation, so they get a colored, bordered, pill-style control
    // instead -- selection is unmistakable at a glance.

    private enum AppTab: String, CaseIterable {
        case create = "Create Master"
        case verify = "Verify Master"

        var icon: String {
            switch self {
            case .create: return "square.and.pencil"
            case .verify: return "checkmark.shield"
            }
        }

        var tint: Color {
            switch self {
            case .create: return .blue
            case .verify: return .green
            }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 8) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: tab.icon)
                        Text(tab.rawValue)
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity)
                    .background(selectedTab == tab ? tab.tint.opacity(0.18) : Color.clear)
                    .foregroundStyle(selectedTab == tab ? tab.tint : .secondary)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(selectedTab == tab ? tab.tint : Color.clear, lineWidth: 1.5)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .background(Color.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding([.horizontal, .top], 16)
        .padding(.bottom, 4)
    }

    private var createMasterTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                inputFolderSection
                optionsSection
                metadataSection
                createActionsSection
                webcamPanel
            }
            .padding(16)
        }
    }

    private var verifyMasterTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                verifyActionsSection
                HStack(alignment: .top, spacing: 16) {
                    usbDrivesPanel
                    bookInfoPanel
                    usbChecksPanel
                    blockHistoryPanel
                    productionPanel
                }
            }
            .padding(16)
        }
    }

    // MARK: ISBN CSV lookup (ports _on_isbn_change)

    private func lookupISBNIfEnabled(_ isbn: String) {
        guard settingsStore.settings.lookupCsv else { return }
        guard isbn.count == 13, isbn.allSatisfy(\.isNumber) else {
            log.append("Invalid ISBN '\(isbn)': must be 13 digits.")
            return
        }
        guard let row = BooksCatalog.lookup(isbn: isbn) else {
            log.append("No catalog data found for \(isbn)")
            settingsStore.settings.sku = ""
            settingsStore.settings.title = ""
            settingsStore.settings.author = ""
            settingsStore.settings.pastMaster.fileCountExpected = 0
            return
        }
        settingsStore.settings.sku = row["SKU"] ?? ""
        settingsStore.settings.title = row["Title"] ?? ""
        settingsStore.settings.author = row["Author"] ?? ""
        settingsStore.settings.pastMaster.fileCountExpected = Int(row["ExpectedFileCount"] ?? "") ?? 0
        log.append("Catalog match for \(isbn): \(row["Title"] ?? "-") by \(row["Author"] ?? "-")")
    }

    // MARK: Row 0 — Input Folder

    private var inputFolderSection: some View {
        GroupBox {
            HStack {
                Text("Input Folder:").frame(width: 110, alignment: .trailing)
                TextField("", text: $settingsStore.settings.inputFolder)
                Button("Browse") { browseForInputFolder() }
            }
        }
    }

    // MARK: Row 1-2 — Options + Max Drive Size

    private var optionsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 24) {
                    Toggle("Skip Image Creation", isOn: $settingsStore.settings.skipImageCreation)
                    Toggle("Skip encoding", isOn: $settingsStore.settings.skipEncoding)
                }
                HStack {
                    Text("Max Drive Size:").frame(width: 110, alignment: .trailing)
                    Picker("", selection: $settingsStore.settings.maxDriveSizeMB) {
                        Text("480 MB").tag("480")
                        Text("980 MB").tag("980")
                    }
                    .pickerStyle(.radioGroup)
                    .horizontalRadioGroupLayout()
                }
                HStack {
                    Text("Image Format:").frame(width: 110, alignment: .trailing)
                    Picker("", selection: $settingsStore.settings.imageFormat) {
                        Text("MBR").tag("mbr")
                        Text("Superfloppy").tag("superfloppy")
                    }
                    .pickerStyle(.radioGroup)
                    .horizontalRadioGroupLayout()
                    Text("(MBR = partitioned FAT32, for hardware that needs a real partition table)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Rows 3-7 — Book metadata (Single / Batch sub-tabs)

    private enum MetadataMode: String, CaseIterable {
        case single = "Single"
        case batch = "Batch"
    }

    private var metadataModeTabs: some View {
        HStack(spacing: 6) {
            ForEach(MetadataMode.allCases, id: \.self) { mode in
                Button(mode.rawValue) { metadataMode = mode }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: metadataMode == mode ? .bold : .regular))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(metadataMode == mode ? Color.accentColor.opacity(0.15) : Color.clear)
                    .foregroundStyle(metadataMode == mode ? Color.accentColor : .secondary)
                    .clipShape(Capsule())
            }
        }
    }

    private var metadataSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                metadataModeTabs
                switch metadataMode {
                case .single: singleMetadataForm
                case .batch: batchMetadataForm
                }
            }
        }
    }

    /// Manual entry is the inverse of the existing (functional) lookupCsv
    /// flag, not the separate `manualData` setting -- that field is
    /// carried over from Python's DEFAULT_SETTINGS but was never actually
    /// read anywhere in either app, so wiring the UI to it would just add
    /// a second dead toggle instead of fixing the framing of the real one.
    private var manualEntryBinding: Binding<Bool> {
        Binding(
            get: { !settingsStore.settings.lookupCsv },
            set: { settingsStore.settings.lookupCsv = !$0 }
        )
    }

    private var singleMetadataForm: some View {
        HStack(alignment: .top, spacing: 12) {
            BookCoverView(sku: settingsStore.settings.sku.isEmpty ? nil : settingsStore.settings.sku)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("ISBN:").frame(width: 110, alignment: .trailing)
                    TextField("", text: $settingsStore.settings.isbn)
                        .frame(maxWidth: 220)
                    Toggle("Find input from ISBN", isOn: $settingsStore.settings.findIsbnFolder)
                    Toggle("Webcam ISBN", isOn: $settingsStore.settings.useWebcam)
                }
                HStack {
                    Text("SKU:").frame(width: 110, alignment: .trailing)
                    TextField("", text: $settingsStore.settings.sku)
                        .frame(maxWidth: 220)
                        .disabled(settingsStore.settings.lookupCsv)
                    Toggle("Manually enter data", isOn: manualEntryBinding)
                }
                HStack {
                    Text("Title:").frame(width: 110, alignment: .trailing)
                    TextField("", text: $settingsStore.settings.title)
                        .disabled(settingsStore.settings.lookupCsv)
                }
                HStack {
                    Text("Author:").frame(width: 110, alignment: .trailing)
                    TextField("", text: $settingsStore.settings.author)
                        .disabled(settingsStore.settings.lookupCsv)
                }
                HStack {
                    Text("File Count:").frame(width: 110, alignment: .trailing)
                    TextField("", value: $settingsStore.settings.pastMaster.fileCountExpected, format: .number)
                        .frame(maxWidth: 100)
                        .disabled(settingsStore.settings.lookupCsv)
                }
            }
        }
    }

    /// Ports main_window.py's load_isbn_csv_and_create_masters(): a
    /// plain CSV/text list of ISBNs (one per line, or first column of
    /// each row), each looked up in the book catalog and matched to a
    /// folder under Input Folder by ISBN (InputFolderResolver), then
    /// built with the same Options-section settings (skip encoding, max
    /// drive size, image format) as Single mode. Continues past
    /// individual failures rather than aborting the whole batch,
    /// matching the Python version's per-ISBN try/except.
    private var batchMetadataForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Creates a master for every ISBN in a CSV/text file (one per line, or first column). Each one is looked up in the book catalog and matched to a folder under Input Folder above by ISBN.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button(isBatchRunning ? "Running\u{2026}" : "Choose ISBN List\u{2026}") { chooseBatchCSVAndRun() }
                    .disabled(isBatchRunning || isBuilding)
                if isBatchRunning { ProgressView().controlSize(.small) }
            }
            if let batchSummary {
                detailRow("Created", String(batchSummary.success))
                detailRow("Failed", String(batchSummary.failed))
            }
        }
    }

    // MARK: Create Master actions

    private var createActionsSection: some View {
        GroupBox {
            HStack(spacing: 16) {
                Button(isBuilding ? "Building\u{2026}" : "Create Master") {
                    createMaster()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isBuilding)
                if isBuilding { ProgressView().controlSize(.small) }
                Spacer()
            }
        }
    }

    // MARK: Verify Master actions

    private var verifyActionsSection: some View {
        GroupBox {
            HStack(spacing: 16) {
                Button(isVerifying ? "Verifying\u{2026}" : "Check Master") {
                    checkMaster()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedDrive == nil || isVerifying)
                if isVerifying { ProgressView().controlSize(.small) }
                Spacer()
            }
        }
    }

    // MARK: Create / Check Master

    private func createMaster() {
        let settings = settingsStore.settings
        let maxDriveSizeBytes = resolvedMaxDriveSizeBytes(settings)

        let inputFolder: URL
        if settings.findIsbnFolder {
            guard let found = InputFolderResolver.resolve(basePath: URL(fileURLWithPath: settings.inputFolder), isbn: settings.isbn) else {
                log.append("Cannot create master: no folder containing ISBN \"\(settings.isbn)\" found under \(settings.inputFolder)")
                return
            }
            inputFolder = found
        } else {
            inputFolder = URL(fileURLWithPath: settings.inputFolder)
        }

        let inputs = MasterInputs(
            isbn: settings.isbn, sku: settings.sku, title: settings.title, author: settings.author,
            inputFolder: inputFolder,
            outputFolder: URL(fileURLWithPath: settings.outputFolder),
            skipEncoding: settings.skipEncoding,
            maxDriveSizeBytes: maxDriveSizeBytes,
            imageFormat: ImageFormat(rawValue: settings.imageFormat) ?? .mbr
        )

        let errors = MasterBuilder.validate(inputs: inputs)
        guard errors.isEmpty else {
            log.append("Cannot create master: \(errors.joined(separator: "; "))")
            return
        }

        isBuilding = true
        log.append("Creating master for \(settings.sku)\u{2026}")
        Task {
            do {
                let result = try await MasterBuilder.build(inputs: inputs) { message in
                    Task { @MainActor in log.append(message) }
                }
                log.append("Master created: \(result.imagePath.path) (\(result.fileCount) tracks, bitrate \(result.bitRateUsed)bps)")
            } catch {
                log.append("Master creation failed: \(error)")
            }
            isBuilding = false
        }
    }

    private func resolvedMaxDriveSizeBytes(_ settings: AppSettings) -> Int64 {
        if let mb = Double(settings.maxDriveSizeMB), mb > 0 {
            return Int64(mb * 1_000_000)
        }
        return Int64(ConfigStore.shared.maxDriveSize)
    }

    private func chooseBatchCSVAndRun() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.commaSeparatedText, .plainText, .text]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        runBatch(csvURL: url)
    }

    private func runBatch(csvURL: URL) {
        guard let text = try? String(contentsOf: csvURL, encoding: .utf8) else {
            log.append("Failed to open ISBN list: \(csvURL.path)")
            return
        }
        let isbns = CSVParser.parse(text).compactMap { $0.first?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !isbns.isEmpty else {
            log.append("No ISBNs found in \(csvURL.lastPathComponent)")
            return
        }

        let settings = settingsStore.settings
        let maxDriveSizeBytes = resolvedMaxDriveSizeBytes(settings)
        let imageFormat = ImageFormat(rawValue: settings.imageFormat) ?? .mbr
        let baseInputFolder = URL(fileURLWithPath: settings.inputFolder)
        let outputFolder = URL(fileURLWithPath: settings.outputFolder)

        isBatchRunning = true
        batchSummary = nil
        log.append("Starting batch: \(isbns.count) ISBN(s) from \(csvURL.lastPathComponent)")

        Task {
            var successCount = 0
            var failedCount = 0
            for isbn in isbns {
                guard let row = BooksCatalog.lookup(isbn: isbn) else {
                    log.append("Skipping ISBN \(isbn): not found in catalog")
                    failedCount += 1
                    continue
                }
                let sku = row["SKU"] ?? ""
                let title = row["Title"] ?? ""
                let author = row["Author"] ?? ""
                guard !sku.isEmpty, !title.isEmpty, !author.isEmpty else {
                    log.append("Skipping ISBN \(isbn): incomplete catalog data")
                    failedCount += 1
                    continue
                }
                guard let resolvedFolder = InputFolderResolver.resolve(basePath: baseInputFolder, isbn: isbn) else {
                    log.append("Skipping ISBN \(isbn): no folder containing this ISBN found under \(baseInputFolder.path)")
                    failedCount += 1
                    continue
                }

                let inputs = MasterInputs(
                    isbn: isbn, sku: sku, title: title, author: author,
                    inputFolder: resolvedFolder, outputFolder: outputFolder,
                    skipEncoding: settings.skipEncoding, maxDriveSizeBytes: maxDriveSizeBytes,
                    imageFormat: imageFormat
                )
                let errors = MasterBuilder.validate(inputs: inputs)
                guard errors.isEmpty else {
                    log.append("Skipping ISBN \(isbn): \(errors.joined(separator: "; "))")
                    failedCount += 1
                    continue
                }
                do {
                    let result = try await MasterBuilder.build(inputs: inputs) { message in
                        Task { @MainActor in log.append("[\(isbn)] \(message)") }
                    }
                    log.append("Created master for ISBN \(isbn) (\(result.fileCount) tracks)")
                    successCount += 1
                } catch {
                    log.append("Error creating master for ISBN \(isbn): \(error)")
                    failedCount += 1
                }
            }
            log.append("Batch complete: \(successCount) created, \(failedCount) failed.")
            batchSummary = (successCount, failedCount)
            isBatchRunning = false
        }
    }

    /// Ports voxmaster's verify(): deep verification (read-speed probe,
    /// audio content inspection, SKU/ISBN cross-validation, artifact
    /// cleanup) — replaces the old checksum-only Check Master
    /// (MasterReader is still available for anything that specifically
    /// wants the build-time checksum, but this is the primary path now).
    private func checkMaster() {
        guard let drive = selectedDrive, let mountPath = drive.mountPath else {
            log.append("No mounted drive selected to check.")
            return
        }
        log.append("Verifying \(mountPath)\u{2026}")
        isVerifying = true
        Task {
            do {
                let result = try await DriveVerifier.verify(
                    mountPoint: URL(fileURLWithPath: mountPath),
                    rawDevicePath: drive.rawDevicePath,
                    skipSpeedTest: false,
                    deepAudioInspect: true,
                    productionLog: productionLog,
                    serial: drive.serialNumber
                )
                verificationResult = result
                let rateNote = result.encodingRateAnomaly ? " \u{26A0}\u{FE0F} encoding rate anomaly" : ""
                log.append(
                    "Verified: SKU=\(result.detectedSKU ?? "-") ISBN=\(result.detectedISBN ?? "-") "
                    + "tracks=\(result.trackCount) read=\(result.readSpeedMibS.map { "\($0) MiB/s" } ?? "skipped") "
                    + "encoding=\(result.encodingKbps.map { "\($0)kbps" } ?? "-")\(rateNote)"
                )
                if result.foundArtifactCount > 0 {
                    log.append("Removed \(result.removedArtifactCount)/\(result.foundArtifactCount) unexpected artifacts: \(result.removedArtifactSamples.joined(separator: ", "))")
                }
            } catch {
                verificationResult = nil
                log.append("Verification failed: \(error)")
            }
            isVerifying = false
        }
    }

    // MARK: Block history ("see the history of any block added to the dock")

    /// Looks up prior writes/duplicator runs for the physical device behind
    /// `drive`, keyed by its IOKit hardware serial (USBSerialLookup), and
    /// logs a one-line summary the moment it's plugged in — this is what
    /// makes history visible on connect, not just after a manual check.
    private func announceHistory(for drive: USBDriveInfo) {
        guard let serial = drive.serialNumber else {
            log.append("\(drive.bsdName): no readable USB serial, history lookup unavailable.")
            return
        }
        guard let history = lookUpHistory(for: drive) else {
            log.append("\(drive.bsdName): production log unavailable.")
            return
        }
        if history.isEmpty {
            log.append("\(drive.bsdName): no prior history for serial \(serial).")
        } else {
            let lastWrite = history.writes.last
            log.append(
                "\(drive.bsdName): \(history.writes.count) prior write(s), \(history.duplicatorRuns.count) duplicator run(s)"
                + (lastWrite.map { " — last written as \($0.sku) at \($0.timestamp)" } ?? "")
                + " (serial \(serial))."
            )
        }
    }

    private func lookUpHistory(for drive: USBDriveInfo?) -> DeviceHistory? {
        guard let serial = drive?.serialNumber, let productionLog else { return nil }
        return try? productionLog.deviceHistory(serial: serial)
    }

    private var blockHistoryPanel: some View {
        GroupBox("Block History") {
            VStack(alignment: .leading, spacing: 6) {
                if selectedDrive?.serialNumber == nil {
                    Text("No readable USB serial for this device.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if let blockHistory {
                    if blockHistory.isEmpty {
                        Text("No prior history for this device.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        detailRow("Writes", String(blockHistory.writes.count))
                        detailRow("Duplicator Runs", String(blockHistory.duplicatorRuns.count))
                        Divider()
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(Array(blockHistory.writes.enumerated()), id: \.offset) { _, write in
                                    Text("\(write.timestamp): \(write.sku)")
                                        .font(.caption2)
                                }
                                ForEach(Array(blockHistory.duplicatorRuns.enumerated()), id: \.offset) { _, run in
                                    Text("\(run.dt ?? "-"): dupe run \(run.result ?? "-")")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 80)
                    }
                } else {
                    Text("Select a device to view history.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 200, alignment: .leading)
        }
    }

    // MARK: Row 9 — Webcam / USB Drives / USB Checks panels

    private var webcamPanel: some View {
        GroupBox("Webcam") {
            VStack(spacing: 4) {
                if camera.isRunning {
                    CameraPreviewView(session: camera.session)
                        .frame(width: 220, height: 160)
                } else {
                    Rectangle()
                        .fill(Color.gray.opacity(0.15))
                        .frame(width: 220, height: 160)
                        .overlay(Text(cameraStatusMessage)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                            .font(.caption)
                            .padding(8))
                }
                if let error = camera.errorMessage {
                    Text(error).font(.caption2).foregroundStyle(.red)
                }
            }
        }
    }

    private var cameraStatusMessage: String {
        switch camera.authorization {
        case .notDetermined: return "Enable \"Webcam ISBN\" to request camera access."
        case .denied: return "Camera access denied.\nEnable it in System Settings \u{2192} Privacy & Security \u{2192} Camera."
        case .restricted: return "Camera access is restricted on this Mac."
        case .authorized: return "Starting camera\u{2026}"
        }
    }

    private var usbDrivesPanel: some View {
        GroupBox(usbMonitor.drives.isEmpty ? "No drives detected" : "Write to...") {
            VStack(alignment: .leading, spacing: 6) {
                if usbMonitor.drives.isEmpty {
                    Text("Waiting for USB devices...")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                } else {
                    List(usbMonitor.drives, selection: $selectedDriveID) { drive in
                        Text("\(drive.volumeName ?? drive.bsdName) (\(drive.bsdName))")
                            .tag(drive.id as String?)
                    }
                    .frame(height: 60)
                }
                Divider()
                Group {
                    detailRow("Capacity", selectedDrive.map { formatBytes($0.totalCapacityBytes) } ?? "-")
                    detailRow("Free", selectedDrive.map { formatBytes($0.availableCapacityBytes) } ?? "-")
                    detailRow("FS", selectedDrive?.volumeKind ?? "-")
                    detailRow("Volume", selectedDrive?.volumeName ?? "-")
                    detailRow("Device", selectedDrive?.rawDevicePath ?? "-")
                }
                Divider()
                if isVerifying {
                    HStack { ProgressView().controlSize(.small); Text("Verifying\u{2026}").font(.caption) }
                }
                Group {
                    detailRow("Content", verificationResult == nil ? "-" : (verificationResult!.isValid ? "Valid" : "Invalid"))
                    detailRow("SKU", verificationResult?.detectedSKU ?? "-")
                    detailRow("ISBN", verificationResult?.detectedISBN ?? "-")
                    detailRow("Tracks", verificationResult.map { String($0.trackCount) } ?? "-")
                    detailRow("Used", verificationResult?.stickUsedMib.map { "\($0) MiB" } ?? "-")
                    detailRow("Read Speed", verificationResult?.readSpeedMibS.map { "\($0) MiB/s" } ?? "-")
                    detailRow("Encoding", encodingRow)
                    detailRow("Artifacts Cleaned", verificationResult.map { "\($0.removedArtifactCount)/\($0.foundArtifactCount)" } ?? "-")
                }
            }
            .frame(width: 240, alignment: .leading)
        }
    }

    private var encodingRow: String {
        guard let result = verificationResult, let kbps = result.encodingKbps else { return "-" }
        return result.encodingRateAnomaly ? "\(kbps)kbps \u{26A0}\u{FE0F}" : "\(kbps)kbps"
    }

    // MARK: Book info (catalog lookup by the verified drive's ISBN)

    /// The catalog row for whatever ISBN verification actually found on
    /// the drive -- not the ISBN typed into the Create Master side --
    /// so this reflects what's physically on the stick being checked.
    private var verifiedBook: BookRow? {
        guard let isbn = verificationResult?.detectedISBN else { return nil }
        return BooksCatalog.lookup(isbn: isbn)
    }

    /// books.csv's Duration column is H:MM (hours:minutes), not the
    /// MM:SS/HH:MM:SS elapsed-time format DuplicatorLogParser deals
    /// with -- an audiobook's declared runtime is always well over a
    /// minute, so treating "01:18" as 1h18m (not 1m18s) is the only
    /// sane reading.
    private func parseCatalogDurationSeconds(_ raw: String?) -> Int? {
        guard let raw, !raw.isEmpty else { return nil }
        let parts = raw.trimmingCharacters(in: .whitespaces).split(separator: ":").map(String.init)
        guard parts.count == 2, let hours = Int(parts[0]), let minutes = Int(parts[1]) else { return nil }
        return hours * 3600 + minutes * 60
    }

    private func formatDuration(_ seconds: Int?) -> String {
        guard let seconds else { return "-" }
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    private var bookInfoPanel: some View {
        GroupBox("Book Info") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    BookCoverView(sku: verificationResult?.detectedSKU, width: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        if let book = verifiedBook {
                            Text(book["Title"] ?? "-").font(.caption).bold().lineLimit(2)
                            Text(book["Author"] ?? "-").font(.caption2).foregroundStyle(.secondary)
                        } else {
                            Text(verificationResult == nil ? "Check a drive to look up its book." : "No catalog match for detected ISBN.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Divider()
                detailRow("Tracks Size", verificationResult?.tracksSizeMib.map { "\($0) MiB" } ?? "-")
                if let book = verifiedBook, let catalogSeconds = parseCatalogDurationSeconds(book["Duration"]),
                   let inferredSeconds = verificationResult?.expectedDurationSeconds {
                    durationComparisonView(catalogSeconds: catalogSeconds, inferredSeconds: inferredSeconds)
                } else {
                    detailRow("Inferred Duration", formatDuration(verificationResult?.expectedDurationSeconds))
                }
            }
            .frame(width: 220, alignment: .leading)
        }
    }

    /// A visual side-by-side comparison rather than a bare match/mismatch
    /// label -- two proportional bars (catalog vs. inferred, scaled to
    /// whichever is longer) plus a colored status badge. 2% margin: the
    /// catalog duration is human-entered and the inferred one comes from
    /// summing real track durations, so a small amount of rounding drift
    /// is expected and shouldn't itself read as a problem, but anything
    /// beyond 2% is flagged red as worth a second look.
    private func durationComparisonView(catalogSeconds: Int, inferredSeconds: Int) -> some View {
        let deltaSeconds = abs(catalogSeconds - inferredSeconds)
        let toleranceSeconds = Int((Double(catalogSeconds) * 0.02).rounded())
        let withinTolerance = deltaSeconds <= toleranceSeconds
        let maxSeconds = max(catalogSeconds, inferredSeconds, 1)
        let statusColor: Color = withinTolerance ? .green : .red

        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Duration").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Image(systemName: withinTolerance ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(statusColor)
                Text(withinTolerance ? "Within 2%" : "\u{0394} \(formatDuration(deltaSeconds))")
                    .font(.caption2).bold()
                    .foregroundStyle(statusColor)
            }
            durationBar(label: "Catalog", seconds: catalogSeconds, maxSeconds: maxSeconds, color: .blue)
            durationBar(label: "Inferred", seconds: inferredSeconds, maxSeconds: maxSeconds, color: statusColor)
        }
    }

    private func durationBar(label: String, seconds: Int, maxSeconds: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text(formatDuration(seconds)).font(.caption2)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.gray.opacity(0.15))
                    Capsule().fill(color)
                        .frame(width: max(4, geo.size.width * CGFloat(seconds) / CGFloat(maxSeconds)))
                }
            }
            .frame(height: 8)
        }
    }

    private var selectedDrive: USBDriveInfo? {
        usbMonitor.drives.first { $0.id == selectedDriveID }
    }

    private func formatBytes(_ bytes: Int64?) -> String {
        guard let bytes else { return "-" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text("\(label):").foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
        .font(.caption)
    }

    private var usbChecksPanel: some View {
        GroupBox("Checks to run...") {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Check on mount", isOn: $settingsStore.settings.usbDriveCheckOnMount)
                ForEach(availableTests, id: \.self) { test in
                    Toggle(test, isOn: testBinding(for: test))
                }
            }
            .frame(width: 160, alignment: .leading)
        }
    }

    // MARK: Production log / duplicator ingestion (ports voxmaster's ingest-dupe/match-dupe/stats)

    private var productionPanel: some View {
        GroupBox("Production Log") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Database Location:").font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("Network share, or blank for local", text: $settingsStore.settings.databasePath)
                        .font(.caption2)
                    Button("Browse\u{2026}") { browseForDatabaseFolder() }
                }
                if let error = productionLogStore.lastError {
                    Text("\u{26A0}\u{FE0F} \(error)").font(.caption2).foregroundStyle(.red)
                } else if let path = productionLogStore.currentPath {
                    Text(path.path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
                Divider()
                Button("Import Duplicator Log\u{2026}") { importDuplicatorLog() }
                if let stats = productionStats {
                    detailRow("Total Runs", String(stats.totalDuplicatorRuns))
                    detailRow("Unique", String(stats.uniqueMatches))
                    detailRow("Ambiguous", String(stats.ambiguousMatches))
                    detailRow("Unmatched", String(stats.unmatchedRuns))
                } else {
                    Text("No duplicator log ingested yet.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 220, alignment: .leading)
        }
    }

    private func browseForDatabaseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose a folder for voxmaster.db (e.g. a mounted network share)."
        if !settingsStore.settings.databasePath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: settingsStore.settings.databasePath)
        }
        if panel.runModal() == .OK, let url = panel.url {
            settingsStore.settings.databasePath = url.path
        }
    }

    private func importDuplicatorLog() {
        guard let productionLog else {
            log.append("Production database unavailable.")
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.text, .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let rows = try DuplicatorLogParser.parseLog(at: url)
            let inserted = try productionLog.insertDuplicatorRuns(sourceFile: url.path, rows: rows)
            log.append("Ingested \(rows.count) row(s) from \(url.lastPathComponent) (inserted \(inserted)).")
            productionStats = try productionLog.stats()
        } catch {
            log.append("Failed to ingest duplicator log: \(error)")
        }
    }

    private func testBinding(for test: String) -> Binding<Bool> {
        Binding(
            get: {
                settingsStore.settings.usbDriveTests
                    .split(separator: ",")
                    .map(String.init)
                    .contains(test)
            },
            set: { isOn in
                var tests = Set(settingsStore.settings.usbDriveTests.split(separator: ",").map(String.init))
                if isOn { tests.insert(test) } else { tests.remove(test) }
                settingsStore.settings.usbDriveTests = availableTests.filter(tests.contains).joined(separator: ",")
            }
        )
    }

    // MARK: Row 13 — Log

    private var logSection: some View {
        GroupBox("Log") {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(log.lines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .id(index)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 160)
                .onChange(of: log.lines.count) { newCount in
                    withAnimation { proxy.scrollTo(newCount - 1, anchor: .bottom) }
                }
            }
        }
    }

    // MARK: Actions

    private func browseForInputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if !settingsStore.settings.inputFolder.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: settingsStore.settings.inputFolder)
        }
        if panel.runModal() == .OK, let url = panel.url {
            settingsStore.settings.inputFolder = url.path
            log.append("Input folder set to \(url.path)")
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(SettingsStore())
        .environmentObject(USBMonitor())
}
