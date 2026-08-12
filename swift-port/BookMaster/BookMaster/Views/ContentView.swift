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
    // Lightweight local instance for now; Phase 14 promotes this to a
    // shared environment object once block-history lookups need it too.
    private let productionLog: ProductionLog? = try? ProductionLog()

    private let availableTests = ["Silence", "Loudness", "Metadata", "Frames", "Speed"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TabView {
                createMasterTab
                    .tabItem { Label("Create Master", systemImage: "square.and.pencil") }
                verifyMasterTab
                    .tabItem { Label("Verify Master", systemImage: "checkmark.shield") }
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
                        Text("Superfloppy").tag("superfloppy")
                        Text("MBR").tag("mbr")
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

    // MARK: Rows 3-7 — Book metadata

    private var metadataSection: some View {
        GroupBox {
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
                    Toggle("CSV lookup", isOn: $settingsStore.settings.lookupCsv)
                }
                HStack {
                    Text("Title:").frame(width: 110, alignment: .trailing)
                    TextField("", text: $settingsStore.settings.title)
                        .disabled(settingsStore.settings.lookupCsv)
                    Button("Batch Create") { log.append("Batch Create (stub — Phase 6/7 wires CSV batch flow)") }
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
                Toggle("Write image to block", isOn: $settingsStore.settings.writeImageMode)
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
        let maxDriveSizeBytes: Int64
        if let mb = Double(settings.maxDriveSizeMB), mb > 0 {
            maxDriveSizeBytes = Int64(mb * 1_000_000)
        } else {
            maxDriveSizeBytes = Int64(ConfigStore.shared.maxDriveSize)
        }

        let inputs = MasterInputs(
            isbn: settings.isbn, sku: settings.sku, title: settings.title, author: settings.author,
            inputFolder: URL(fileURLWithPath: settings.inputFolder),
            outputFolder: URL(fileURLWithPath: settings.outputFolder),
            skipEncoding: settings.skipEncoding,
            maxDriveSizeBytes: maxDriveSizeBytes,
            imageFormat: ImageFormat(rawValue: settings.imageFormat) ?? .superfloppy
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
                if settings.writeImageMode {
                    log.append("\"Write image to block\" is on, but writing to a real device needs a selected drive and is not driven from this button in an unattended way \u{2014} select a drive and confirm manually (Phase 4/9: no privileged write helper yet).")
                }
            } catch {
                log.append("Master creation failed: \(error)")
            }
            isBuilding = false
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
            VStack(alignment: .leading, spacing: 6) {
                if let book = verifiedBook {
                    detailRow("Title", book["Title"] ?? "-")
                    detailRow("Author", book["Author"] ?? "-")
                    Divider()
                    detailRow("Catalog Duration", book["Duration"] ?? "-")
                } else {
                    Text(verificationResult == nil ? "Check a drive to look up its book." : "No catalog match for detected ISBN.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Divider()
                detailRow("Tracks Size", verificationResult?.tracksSizeMib.map { "\($0) MiB" } ?? "-")
                detailRow("Inferred Duration", formatDuration(verificationResult?.expectedDurationSeconds))
                if let book = verifiedBook, let catalogSeconds = parseCatalogDurationSeconds(book["Duration"]),
                   let inferredSeconds = verificationResult?.expectedDurationSeconds {
                    detailRow("Duration Match", durationMatchLabel(catalogSeconds: catalogSeconds, inferredSeconds: inferredSeconds))
                }
            }
            .frame(width: 200, alignment: .leading)
        }
    }

    /// Flags a mismatch beyond a small tolerance rather than demanding
    /// exact equality -- the catalog's duration is a human-entered
    /// runtime, the inferred one comes from summing real track
    /// durations, so a few seconds/minutes of rounding drift is
    /// expected and not itself a sign anything is wrong.
    private func durationMatchLabel(catalogSeconds: Int, inferredSeconds: Int) -> String {
        let deltaSeconds = abs(catalogSeconds - inferredSeconds)
        let toleranceSeconds = max(60, catalogSeconds / 20)
        return deltaSeconds <= toleranceSeconds ? "Match" : "Mismatch (\u{0394} \(formatDuration(deltaSeconds)))"
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
            .frame(width: 180, alignment: .leading)
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
