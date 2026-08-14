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
    @State private var isCancellingBuild = false
    @State private var buildProgress: Double = 0
    @State private var buildPhaseDescription = ""
    @State private var buildTask: Task<Void, Never>?
    @State private var verificationResult: VerificationResult?
    @State private var isVerifying = false
    @State private var fixRemoveArtifacts = true
    @State private var fixCleanID3Tags = true
    @State private var isFixing = false
    @State private var fixResult: MasterFixSummary?
    @State private var productionStats: ProductionStats?
    @State private var blockHistory: DeviceHistory?
    @State private var selectedTab: AppTab = .create
    @State private var metadataMode: MetadataMode = .single
    @State private var isBatchRunning = false
    @State private var batchSummary: (success: Int, failed: Int)?
    @State private var duplicatorSyncSummary: DuplicatorSyncSummary?
    @State private var isSyncingDuplicatorLogs = false
    @State private var isEjecting = false
    @State private var isLogPanelVisible = true
    @State private var logPanelWidth: CGFloat = 300
    @State private var logPanelWidthAtDragStart: CGFloat?
    private let logPanelWidthRange: ClosedRange<CGFloat> = 220...600
    @StateObject private var productionLogStore = ProductionLogStore()
    // Write to Block
    @State private var masterSelectionMode: MasterSelectionMode = .manual
    @State private var masterSelectionInput = ""
    @State private var resolvedMaster: ResolvedMaster?
    @State private var masterResolveError: String?
    @State private var availableMasters: [MasterRecord] = []
    @State private var isWriting = false
    @State private var showWriteConfirmation = false
    @State private var writeResult: MasterWriteResult?
    @State private var writeError: String?
    // Separate from `camera` (Create Master's ISBN-lookup webcam) so the
    // two scan flows never cross-talk through a shared onChange handler.
    @StateObject private var writeCamera = CameraScanner()

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
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 12) {
                    tabBar
                    Spacer(minLength: 12)
                    ejectButton
                        .padding(.trailing, 8)
                    logPanelToggleButton
                        .padding(.trailing, 16)
                }
                Group {
                    switch selectedTab {
                    case .create: createMasterTab
                    case .verify: verifyMasterTab
                    case .dataImport: importTab
                    }
                }
            }
            if isLogPanelVisible {
                logPanelResizeHandle
                logSidebar
            }
        }
        .onAppear {
            log.append("Loaded settings from \(settingsStore.settingsFilePath)")
            log.append("Config: bit_rate=\(ConfigStore.shared.encoding.bitRate) max_drive_size=\(ConfigStore.shared.maxDriveSize)")
            if selectedDriveID == nil, let first = usbMonitor.drives.first {
                selectedDriveID = first.id
            }
            productionLogStore.open(inDirectory: resolvedDatabaseDirectory())
            syncDuplicatorLogs()
        }
        .onChange(of: settingsStore.settings.databasePath) { _ in
            productionLogStore.open(inDirectory: resolvedDatabaseDirectory())
            if let error = productionLogStore.lastError {
                log.append("Could not open production database at new location: \(error)")
            } else if let path = productionLogStore.currentPath {
                log.append("Production database: \(path.path)")
            }
        }
        .onChange(of: settingsStore.settings.duplicatorLogFolder) { _ in
            syncDuplicatorLogs()
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
                settingsStore.settings.lookupCsv = true
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
        .onChange(of: writeCamera.lastDetectedISBN) { isbn in
            guard let isbn else { return }
            masterSelectionInput = isbn
            log.append("Scanned ISBN \(isbn)")
            resolveMasterSelection()
        }
        .onChange(of: masterSelectionMode) { mode in
            if mode == .scan {
                writeCamera.start()
            } else {
                writeCamera.stop()
            }
            if mode == .list {
                refreshAvailableMasters()
            }
        }
    }

    // MARK: Create Master / Verify Master / Import tabs
    //
    // Splits the single Python window into the sides the app actually
    // has: authoring a new master image, inspecting/verifying a
    // connected drive, and the production-log/duplicator-log ingestion
    // side (its own tab rather than squeezed into Verify Master's panel
    // row, which was already tight before adding a fifth panel there).
    // The log lives in a persistent sidebar (see logSidebar) rather than
    // under any one tab, since all three write to it.
    //
    // A custom tab bar, not native TabView chrome: macOS's default top
    // tab strip is a small, low-contrast row of icon+label buttons that
    // reads as secondary UI. These tabs ARE the app's primary
    // navigation, so they get a colored, bordered, pill-style control
    // instead -- selection is unmistakable at a glance.

    private enum AppTab: String, CaseIterable {
        case create = "Create Master"
        case verify = "Verify Master"
        case dataImport = "Import"

        var icon: String {
            switch self {
            case .create: return "square.and.pencil"
            case .verify: return "checkmark.shield"
            case .dataImport: return "tray.and.arrow.down"
            }
        }

        var tint: Color {
            switch self {
            case .create: return .blue
            case .verify: return .green
            case .dataImport: return .orange
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

    // MARK: Eject (visible in every tab, not just Verify Master's drive
    // list -- the point is a one-click "safe to unplug" that works no
    // matter what the operator was doing when they're ready to pull the
    // stick, without making them switch tabs first).

    /// Whichever drive the eject button acts on: the one selected in
    /// Verify Master's list if there is one, else the sole/first
    /// candidate -- matching selectedDriveID's own autoselect-first-drive
    /// default, so on the common single-drive-connected case this just
    /// works without the operator ever having picked anything.
    private var ejectableDrive: USBDriveInfo? {
        selectedDrive ?? usbMonitor.drives.first
    }

    private var ejectButton: some View {
        Group {
            if let drive = ejectableDrive {
                Button {
                    ejectDrive(drive)
                } label: {
                    HStack(spacing: 6) {
                        if isEjecting {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "eject.fill")
                        }
                        Text(isEjecting ? "Ejecting\u{2026}" : "Eject \(drive.volumeName ?? drive.bsdName)")
                    }
                    .font(.system(size: 12, weight: .medium))
                }
                .disabled(isEjecting)
                .help("Unmount and eject \(drive.volumeName ?? drive.bsdName) (\(drive.bsdName))")
            }
        }
    }

    private func ejectDrive(_ drive: USBDriveInfo) {
        isEjecting = true
        log.append("Ejecting \(drive.volumeName ?? drive.bsdName) (\(drive.bsdName))\u{2026}")
        Task {
            do {
                try await usbMonitor.eject(bsdName: drive.bsdName)
                log.append("\(drive.bsdName) ejected \u{2014} safe to unplug.")
            } catch {
                log.append("Eject failed: \(error.localizedDescription)")
            }
            isEjecting = false
        }
    }

    private var createMasterTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Group {
                    inputFolderSection
                    optionsSection
                    metadataSection
                }
                .disabled(isBuilding)
                createActionsSection
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var verifyMasterTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                verifyActionsSection
                writeToBlockSection
                // A plain (non-scrolling) HStack here would overflow once the
                // log sidebar eats into the window's width -- SwiftUI's
                // vertical ScrollView center-clips oversized cross-axis
                // content rather than left-aligning it, which silently cuts
                // the leading panel off the left edge instead of the
                // trailing one off the right. Its own horizontal ScrollView
                // makes that overflow scroll (leading-anchored) instead.
                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(alignment: .top, spacing: 16) {
                        usbDrivesPanel
                        bookInfoPanel
                        usbChecksPanel
                        masterFixPanel
                        blockHistoryPanel
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var importTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                productionPanel
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
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

    // MARK: Row 0 — Input / Output Folders

    private var inputFolderSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Input Folder:").frame(width: 110, alignment: .trailing)
                    TextField("", text: $settingsStore.settings.inputFolder)
                    Button("Browse") { browseForInputFolder() }
                }
                HStack {
                    Text("Output Folder:").frame(width: 110, alignment: .trailing)
                    TextField("", text: $settingsStore.settings.outputFolder)
                    Button("Browse") { browseForOutputFolder() }
                }
            }
        }
    }

    // MARK: Row 1-2 — Options + Max Drive Size

    private var optionsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 24) {
                    Toggle("Strip Audio Tags", isOn: $settingsStore.settings.stripInputTags)
                        .help("Encode without carrying over the input file's own metadata or writing any ID3 tag on the output track.")
                    HStack(spacing: 4) {
                        Toggle("Cache files", isOn: $settingsStore.settings.cacheFiles)
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                            .help("Keeps successfully re-encoded tracks on disk instead of deleting them. If Create Master is cancelled or fails partway through, this partial progress will NOT be removed -- re-running will skip the tracks already done and only encode the ones that didn't finish, so one bad file doesn't cost you the rest of the batch. Leave this off to always start each run from a clean slate.")
                    }
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
                HStack {
                    Text("Sample Rate:").frame(width: 110, alignment: .trailing)
                    Picker("", selection: $settingsStore.settings.sampleRate) {
                        Text("44.1 kHz").tag(44100)
                        Text("48 kHz").tag(48000)
                    }
                    .pickerStyle(.radioGroup)
                    .horizontalRadioGroupLayout()
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
                    Toggle("Find folder containing ISBN", isOn: $settingsStore.settings.findIsbnFolder)
                }
                HStack {
                    Text("SKU:").frame(width: 110, alignment: .trailing)
                    TextField("", text: $settingsStore.settings.sku)
                        .frame(maxWidth: 220)
                        .disabled(settingsStore.settings.lookupCsv)
                    Toggle("Manually enter data", isOn: manualEntryBinding)
                        .disabled(settingsStore.settings.useWebcam)
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
                HStack {
                    Spacer().frame(width: 110)
                    Button {
                        fillTestData()
                    } label: {
                        Label("Generate Test Data", systemImage: "wand.and.stars")
                    }
                    .disabled(settingsStore.settings.useWebcam)
                    .help("Fills ISBN/SKU/Title/Author/File Count with made-up placeholder values for exercising this form without a real catalog entry.")
                }
            }
            Spacer(minLength: 12)
            webcamPanel
        }
    }

    /// Fills the Single metadata form with made-up but plausible values
    /// (see TestDataGenerator) -- switches to manual entry first so the
    /// CSV catalog lookup triggered by setting `isbn` doesn't immediately
    /// overwrite them with "no catalog match" blanks.
    private func fillTestData() {
        let data = TestDataGenerator.generate()
        settingsStore.settings.lookupCsv = false
        settingsStore.settings.isbn = data.isbn
        settingsStore.settings.sku = data.sku
        settingsStore.settings.title = data.title
        settingsStore.settings.author = data.author
        settingsStore.settings.pastMaster.fileCountExpected = data.fileCount
        log.append("Generated test data: \(data.sku) \u{2014} \u{201C}\(data.title)\u{201D} by \(data.author) (ISBN \(data.isbn), \(data.fileCount) files)")
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
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Button(isBuilding ? "Building\u{2026}" : "Create Master") {
                        createMaster()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isBuilding)
                    if isBuilding {
                        Button(isCancellingBuild ? "Cancelling\u{2026}" : "Cancel", role: .destructive) {
                            cancelMasterCreation()
                        }
                        .disabled(isCancellingBuild)
                    }
                    Spacer()
                }
                if isBuilding {
                    VStack(alignment: .leading, spacing: 2) {
                        ProgressView(value: buildProgress)
                            .frame(maxWidth: .infinity)
                        Text(buildPhaseDescription)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
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
                .disabled(selectedDrive?.mountPath == nil || isVerifying)
                .help(selectedDrive?.mountPath == nil ? "Selected drive isn't mounted -- mount it first." : "")
                if isVerifying { ProgressView().controlSize(.small) }
                Spacer()
            }
        }
    }

    // MARK: Write to Block (ports voxmaster's writer.py write(), adapted to
    // native I/O -- see MasterWriter/MasterResolver)

    private enum MasterSelectionMode: String, CaseIterable {
        case manual = "Enter"
        case scan = "Scan"
        case list = "List"
    }

    private var writeToBlockSection: some View {
        GroupBox("Write to Block") {
            HStack(alignment: .top, spacing: 16) {
                // Fixed-width left column regardless of mode, so switching
                // Enter/Scan/List doesn't reflow the rest of the tab --
                // only the reserved slot to its right (webcam for Scan,
                // the cataloged-masters list for List) changes.
                VStack(alignment: .leading, spacing: 10) {
                    masterSelectionModeTabs
                    if masterSelectionMode == .manual {
                        manualMasterSelection
                    }
                    Divider()
                    detailRow("Selected", resolvedMaster?.sku ?? "-")
                    detailRow("Image Size", resolvedMaster.map { "\($0.imageMib) MiB" } ?? "-")
                    if let masterResolveError {
                        Text(masterResolveError).font(.caption2).foregroundStyle(.red)
                    }
                    Divider()
                    HStack(spacing: 12) {
                        Button(isWriting ? "Writing\u{2026}" : "Write to Block") { showWriteConfirmation = true }
                            .buttonStyle(.borderedProminent)
                            .disabled(resolvedMaster == nil || selectedDrive == nil || isWriting)
                        if isWriting { ProgressView().controlSize(.small) }
                    }
                    if let writeResult {
                        Divider()
                        detailRow("Write Speed", "\(writeResult.throughputImageMibS) MiB/s")
                        detailRow("Elapsed", "\(writeResult.elapsedSeconds)s")
                        detailRow("Tracks", String(writeResult.trackCount))
                        detailRow("Expected Duration", formatDuration(writeResult.expectedDurationSeconds))
                        detailRow("Encoding", writeResult.encodingKbps.map {
                            writeResult.encodingRateAnomaly ? "\($0)kbps \u{26A0}\u{FE0F}" : "\($0)kbps"
                        } ?? "-")
                        detailRow("Artifacts Cleaned", "\(writeResult.removedArtifactCount)/\(writeResult.foundArtifactCount)")
                        detailRow("Serial", writeResult.serial ?? "-")
                    }
                    if let writeError {
                        Text(writeError).font(.caption2).foregroundStyle(.red)
                    }
                }
                .frame(width: 240, alignment: .leading)

                switch masterSelectionMode {
                case .manual: EmptyView()
                case .scan: scanMasterSelection
                case .list: listMasterSelection
                }
            }
        }
        .confirmationDialog(
            "Write \(resolvedMaster?.sku ?? "") to \(selectedDrive?.bsdName ?? "this drive")?",
            isPresented: $showWriteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Write \u{2014} Erases Existing Content", role: .destructive) { performWrite() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This erases all existing content on \(selectedDrive?.volumeName ?? selectedDrive?.bsdName ?? "the selected drive") (\(resolvedMaster?.imageMib ?? 0) MiB image).")
        }
    }

    private var masterSelectionModeTabs: some View {
        HStack(spacing: 6) {
            ForEach(MasterSelectionMode.allCases, id: \.self) { mode in
                Button(mode.rawValue) { masterSelectionMode = mode }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: masterSelectionMode == mode ? .bold : .regular))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(masterSelectionMode == mode ? Color.accentColor.opacity(0.15) : Color.clear)
                    .foregroundStyle(masterSelectionMode == mode ? Color.accentColor : .secondary)
                    .clipShape(Capsule())
            }
        }
    }

    private var manualMasterSelection: some View {
        HStack {
            TextField("ISBN or SKU", text: $masterSelectionInput)
                .frame(maxWidth: 200)
                .onSubmit { resolveMasterSelection() }
            Button("Find") { resolveMasterSelection() }
                .disabled(masterSelectionInput.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    /// Reuses the same CameraScanner/Vision pipeline as Create Master's
    /// webcam ISBN lookup -- currently EAN-13/ISBN-13 only (see
    /// CameraScanner.isPlausibleISBN13). If a physical master block's
    /// printed barcode is actually a SKU-format code rather than the
    /// book's ISBN, this won't detect it yet; that'd need widening
    /// CameraScanner's symbology list and payload filter, not something
    /// to assume without knowing what the real labels look like.
    private var scanMasterSelection: some View {
        GroupBox("Webcam") {
            VStack(alignment: .leading, spacing: 4) {
                if writeCamera.isRunning {
                    CameraPreviewView(session: writeCamera.session)
                        .frame(width: 200, height: 140)
                } else {
                    Rectangle()
                        .fill(Color.gray.opacity(0.15))
                        .frame(width: 200, height: 140)
                        .overlay(Text("Starting camera\u{2026}").font(.caption2).foregroundStyle(.secondary))
                }
                if let error = writeCamera.errorMessage {
                    Text(error).font(.caption2).foregroundStyle(.red)
                }
            }
        }
    }

    private var listMasterSelection: some View {
        GroupBox("Cataloged Masters") {
            VStack(alignment: .leading, spacing: 4) {
                if availableMasters.isEmpty {
                    Text("No cataloged masters yet.").font(.caption2).foregroundStyle(.secondary)
                } else {
                    List(availableMasters, id: \.sku) { record in
                        Button(record.sku) {
                            masterSelectionInput = record.sku
                            resolveMasterSelection()
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(width: 200, height: 100)
                }
                Button("Refresh List") { refreshAvailableMasters() }
            }
        }
    }

    private func refreshAvailableMasters() {
        guard let productionLog else { availableMasters = []; return }
        availableMasters = (try? productionLog.allMasters()) ?? []
    }

    private func resolveMasterSelection() {
        let outputFolder = URL(fileURLWithPath: settingsStore.settings.outputFolder)
        switch MasterResolver.resolve(input: masterSelectionInput, outputFolder: outputFolder, productionLog: productionLog) {
        case .success(let master):
            resolvedMaster = master
            masterResolveError = nil
            log.append("Selected master \(master.sku) (\(master.imageMib) MiB) at \(master.imagePath.path)")
        case .failure(let error):
            resolvedMaster = nil
            masterResolveError = error.description
        }
    }

    private func performWrite() {
        guard let resolvedMaster, let drive = selectedDrive else { return }
        isWriting = true
        writeResult = nil
        writeError = nil
        log.append("Writing \(resolvedMaster.sku) to \(drive.bsdName)\u{2026}")
        Task {
            do {
                let result = try await MasterWriter.write(
                    master: resolvedMaster, drive: drive, currentCandidates: usbMonitor.drives,
                    productionLog: productionLog
                ) { message in
                    Task { @MainActor in log.append(message) }
                }
                writeResult = result
                log.append("Write complete: \(result.trackCount) tracks, \(result.throughputImageMibS) MiB/s, \(result.elapsedSeconds)s")
                if result.encodingRateAnomaly {
                    log.append("\u{26A0}\u{FE0F} encoding rate anomaly detected on written content")
                }
                blockHistory = lookUpHistory(for: drive)
            } catch {
                writeError = "\(error)"
                log.append("Write failed: \(error)")
            }
            isWriting = false
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
            maxDriveSizeBytes: maxDriveSizeBytes,
            imageFormat: ImageFormat(rawValue: settings.imageFormat) ?? .mbr,
            stripInputTags: settings.stripInputTags,
            cacheFiles: settings.cacheFiles,
            sampleRate: settings.sampleRate
        )

        let errors = MasterBuilder.validate(inputs: inputs)
        guard errors.isEmpty else {
            log.append("Cannot create master: \(errors.joined(separator: "; "))")
            return
        }

        isBuilding = true
        isCancellingBuild = false
        buildProgress = 0
        buildPhaseDescription = "Starting\u{2026}"
        log.append("Creating master for \(settings.sku)\u{2026}")
        buildTask = Task {
            do {
                let result = try await MasterBuilder.build(
                    inputs: inputs,
                    productionLog: productionLog,
                    progress: { progress in
                        Task { @MainActor in
                            buildProgress = progress.fractionComplete
                            switch progress.phase {
                            case .encoding(let track, let totalTracks):
                                buildPhaseDescription = "Encoding track \(track)/\(totalTracks)\u{2026}"
                            case .buildingImage:
                                buildPhaseDescription = "Building disk image\u{2026}"
                            }
                        }
                    },
                    log: { message in
                        Task { @MainActor in log.append(message) }
                    }
                )
                log.append("Master created: \(result.imagePath.path) (\(result.fileCount) tracks, bitrate \(result.bitRateUsed)bps)")
            } catch is CancellationError {
                log.append("Master creation cancelled.")
            } catch {
                log.append("Master creation failed: \(error)")
            }
            isBuilding = false
            isCancellingBuild = false
            buildTask = nil
        }
    }

    private func cancelMasterCreation() {
        guard !isCancellingBuild else { return }
        isCancellingBuild = true
        log.append("Cancelling master creation\u{2026}")
        buildTask?.cancel()
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
                    maxDriveSizeBytes: maxDriveSizeBytes,
                    imageFormat: imageFormat, stripInputTags: settings.stripInputTags,
                    cacheFiles: settings.cacheFiles, sampleRate: settings.sampleRate
                )
                let errors = MasterBuilder.validate(inputs: inputs)
                guard errors.isEmpty else {
                    log.append("Skipping ISBN \(isbn): \(errors.joined(separator: "; "))")
                    failedCount += 1
                    continue
                }
                do {
                    let result = try await MasterBuilder.build(inputs: inputs, productionLog: productionLog) { message in
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
                    log.append("Found \(result.foundArtifactCount) unexpected artifact(s): \(result.foundArtifactSamples.joined(separator: ", "))")
                }
                if result.hasID3TagIssues {
                    let detail = result.id3TagIssues.map { "\($0.fileName) (\($0.reason))" }.joined(separator: "; ")
                    log.append("\u{26A0}\u{FE0F} ID3 tag issues found on \(result.id3TagIssues.count) track file(s): \(detail)")
                }
            } catch {
                verificationResult = nil
                log.append("Verification failed: \(error)")
            }
            isVerifying = false
        }
    }

    // MARK: Fix Master (MasterFixer -- the explicit, opt-in counterpart
    // to Check Master's read-only report)

    private struct MasterFixSummary {
        let artifactsFound: Int
        let artifactsRemoved: Int
        let id3FilesFlagged: Int
        let id3FilesCleaned: Int
    }

    private var masterFixPanel: some View {
        GroupBox("Fixes to make...") {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Remove File Artefacts", isOn: $fixRemoveArtifacts)
                Toggle("Clean ID3 Tags", isOn: $fixCleanID3Tags)
                Divider()
                HStack(spacing: 8) {
                    Button(isFixing ? "Fixing\u{2026}" : "Fix Master") { fixMaster() }
                        .buttonStyle(.borderedProminent)
                        .disabled(selectedDrive?.mountPath == nil || isFixing || (!fixRemoveArtifacts && !fixCleanID3Tags))
                    if isFixing { ProgressView().controlSize(.small) }
                }
                if let fixResult {
                    Divider()
                    if fixRemoveArtifacts {
                        detailRow("Artefacts", "\(fixResult.artifactsRemoved)/\(fixResult.artifactsFound)")
                    }
                    if fixCleanID3Tags {
                        detailRow("ID3 Cleaned", "\(fixResult.id3FilesCleaned)/\(fixResult.id3FilesFlagged)")
                    }
                }
            }
            .frame(width: 160, alignment: .leading)
        }
    }

    /// Applies whichever fixes are checked to the selected drive, then
    /// re-runs Check Master so the panels reflect the now-fixed state
    /// rather than showing stale pre-fix issue counts.
    private func fixMaster() {
        guard let drive = selectedDrive, let mountPath = drive.mountPath else {
            log.append("No mounted drive selected to fix.")
            return
        }
        isFixing = true
        fixResult = nil
        log.append("Fixing \(mountPath)\u{2026}")
        let isbn = verificationResult?.detectedISBN
        Task {
            var artifactsFound = 0
            var artifactsRemoved = 0
            var id3Flagged = 0
            var id3Cleaned = 0

            if fixRemoveArtifacts {
                let result = MasterFixer.removeArtifacts(at: URL(fileURLWithPath: mountPath))
                (artifactsFound, artifactsRemoved) = (result.found, result.removed)
                if result.found > 0 {
                    log.append("Removed \(result.removed)/\(result.found) unexpected artifact(s): \(result.samples.joined(separator: ", "))")
                } else {
                    log.append("No unexpected artifacts found.")
                }
            }
            if fixCleanID3Tags {
                let tracksPath = URL(fileURLWithPath: mountPath).appendingPathComponent("tracks")
                let result = MasterFixer.cleanID3Tags(tracksPath: tracksPath, isbn: isbn)
                (id3Flagged, id3Cleaned) = (result.flagged, result.cleaned)
                if result.flagged > 0 {
                    log.append("Cleaned ID3 tags on \(result.cleaned)/\(result.flagged) track file(s): \(result.samples.joined(separator: ", "))")
                } else {
                    log.append("No ID3 tag issues found to clean.")
                }
            }

            fixResult = MasterFixSummary(
                artifactsFound: artifactsFound, artifactsRemoved: artifactsRemoved,
                id3FilesFlagged: id3Flagged, id3FilesCleaned: id3Cleaned
            )
            isFixing = false
            checkMaster()
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
                Toggle("Scan barcode", isOn: $settingsStore.settings.useWebcam)
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
                    detailRow("Artifacts Found", verificationResult.map { String($0.foundArtifactCount) } ?? "-")
                    id3TagsRow
                }
            }
            .frame(width: 240, alignment: .leading)
        }
    }

    private var encodingRow: String {
        guard let result = verificationResult, let kbps = result.encodingKbps else { return "-" }
        return result.encodingRateAnomaly ? "\(kbps)kbps \u{26A0}\u{FE0F}" : "\(kbps)kbps"
    }

    /// Its own row rather than a plain detailRow -- an ID3 tag issue is
    /// a "you probably want to look at this" problem, not just one more
    /// data point, so it gets a colored warning icon (the pattern
    /// durationComparisonView already uses below) rather than the
    /// silent-until-you-look-closely emoji-in-a-string the encoding
    /// anomaly row uses. Correctly-tagged tracks (the expected case --
    /// see DriveVerifier.scanForID3TagIssues) show as "OK", not flagged.
    private var id3TagsRow: some View {
        HStack {
            Text("ID3 Tags:").foregroundStyle(.secondary)
            Spacer()
            if let result = verificationResult {
                if result.hasID3TagIssues {
                    Label("\(result.id3TagIssues.count) issue(s)", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                } else {
                    Text("OK")
                }
            } else {
                Text("-")
            }
        }
        .font(.caption)
        .help(id3TagsHelpText)
    }

    private var id3TagsHelpText: String {
        guard let result = verificationResult, result.hasID3TagIssues else { return "" }
        return result.id3TagIssues.map { "\($0.fileName): \($0.reason)" }.joined(separator: "\n")
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
                Divider()
                id3TagIssuesSection
            }
            .frame(width: 220, alignment: .leading)
        }
    }

    /// The per-file detail behind usbDrivesPanel's compact "ID3 Tags"
    /// summary row -- that row answers "is there a problem?" at a
    /// glance, this answers "which file, and what's wrong with it?"
    /// once there is one. Same list-under-a-divider shape as
    /// blockHistoryPanel's write/duplicator-run history below.
    private var id3TagIssuesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("ID3 Tag Issues").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if verificationResult?.hasID3TagIssues == true {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
            }
            if let result = verificationResult {
                if result.hasID3TagIssues {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(result.id3TagIssues.enumerated()), id: \.offset) { _, issue in
                                Text("\(issue.fileName): \(issue.reason)")
                                    .font(.caption2)
                                    .foregroundStyle(.red)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 70)
                } else {
                    Text("No ID3 tag issues.").font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Text("Check a drive to see ID3 tag status.").font(.caption2).foregroundStyle(.secondary)
            }
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

    // MARK: Import tab -- production log / duplicator ingestion (ports voxmaster's ingest-dupe/match-dupe/stats)

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
                Divider()
                Text("Log Folder (auto-sync):").font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("NAS/network folder, or blank to disable", text: $settingsStore.settings.duplicatorLogFolder)
                        .font(.caption2)
                    Button("Browse\u{2026}") { browseForDuplicatorLogFolder() }
                }
                HStack(spacing: 8) {
                    Button(isSyncingDuplicatorLogs ? "Syncing\u{2026}" : "Sync Now") { syncDuplicatorLogs() }
                        .disabled(settingsStore.settings.duplicatorLogFolder.isEmpty || isSyncingDuplicatorLogs)
                    if isSyncingDuplicatorLogs { ProgressView().controlSize(.small) }
                }
                if let summary = duplicatorSyncSummary {
                    if summary.isEmpty {
                        Text("Up to date (\(summary.skippedAlreadySyncedCount) already synced).")
                            .font(.caption2).foregroundStyle(.secondary)
                    } else {
                        detailRow("Synced", "\(summary.syncedFileNames.count) file(s), \(summary.rowsInserted) row(s)")
                        if !summary.failures.isEmpty {
                            detailRow("Failed", String(summary.failures.count))
                        }
                    }
                }
                Divider()
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
            .frame(minWidth: 280, maxWidth: 480, alignment: .leading)
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

    private func browseForDuplicatorLogFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder the duplicator machine's log files land in (e.g. a NAS folder synced from Google Drive)."
        if !settingsStore.settings.duplicatorLogFolder.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: settingsStore.settings.duplicatorLogFolder)
        }
        if panel.runModal() == .OK, let url = panel.url {
            // Setting this triggers .onChange(of: duplicatorLogFolder),
            // which runs the sync -- not called explicitly here too, to
            // avoid two overlapping sync passes racing each other.
            settingsStore.settings.duplicatorLogFolder = url.path
        }
    }

    /// Ingests every duplicator log file in the configured folder not
    /// already synced (by filename -- see DuplicatorLogSync), the same
    /// way "Import Duplicator Log..." ingests one file picked by hand.
    /// Safe to call repeatedly (on launch, on folder change, and via
    /// "Sync Now"): already-synced files are skipped, not re-ingested.
    private func syncDuplicatorLogs() {
        let trimmed = settingsStore.settings.duplicatorLogFolder.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let productionLog else { return }
        isSyncingDuplicatorLogs = true
        let folder = URL(fileURLWithPath: trimmed, isDirectory: true)
        Task {
            let summary = await DuplicatorLogSync.sync(folder: folder, productionLog: productionLog) { message in
                Task { @MainActor in log.append(message) }
            }
            duplicatorSyncSummary = summary
            if !summary.isEmpty {
                productionStats = try? productionLog.stats()
            }
            isSyncingDuplicatorLogs = false
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

    // MARK: Log panel (right-hand sidebar, collapsible)
    //
    // Moved out of the per-tab scroll flow and into a persistent sidebar
    // -- both tabs write to the same log, so it reads better as a
    // constant strip alongside whichever tab is active than as a
    // section that scrolls out of view at the bottom of a long form.
    // Collapsible because during normal operation (once a workflow's
    // trusted) it's just vertical space the actual controls could use.

    private var logPanelToggleButton: some View {
        Button {
            withAnimation { isLogPanelVisible.toggle() }
        } label: {
            Image(systemName: isLogPanelVisible ? "sidebar.trailing" : "sidebar.leading")
        }
        .buttonStyle(.plain)
        .help(isLogPanelVisible ? "Hide log panel" : "Show log panel")
    }

    /// A wider invisible hit-area around a hairline Divider -- a bare
    /// Divider is 1pt, far too thin to reliably grab with a mouse -- that
    /// drags `logPanelWidth` and swaps in a resize cursor on hover, the
    /// same feel as NSSplitView's divider.
    private var logPanelResizeHandle: some View {
        ZStack {
            Color.clear
            Divider()
        }
        .frame(width: 7)
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                NSCursor.resizeLeftRight.push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if logPanelWidthAtDragStart == nil {
                        logPanelWidthAtDragStart = logPanelWidth
                    }
                    let base = logPanelWidthAtDragStart ?? logPanelWidth
                    let proposed = base - value.translation.width
                    logPanelWidth = min(max(proposed, logPanelWidthRange.lowerBound), logPanelWidthRange.upperBound)
                }
                .onEnded { _ in
                    logPanelWidthAtDragStart = nil
                }
        )
    }

    private var logSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Log").font(.headline)
                Spacer()
                Button {
                    withAnimation { isLogPanelVisible = false }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Hide log panel")
            }
            .padding(12)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(log.lines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                                .id(index)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                }
                .onChange(of: log.lines.count) { newCount in
                    withAnimation { proxy.scrollTo(newCount - 1, anchor: .bottom) }
                }
            }
        }
        .frame(width: logPanelWidth)
        .frame(maxHeight: .infinity)
        .background(Color.gray.opacity(0.05))
        .transition(.move(edge: .trailing))
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

    private func browseForOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if !settingsStore.settings.outputFolder.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: settingsStore.settings.outputFolder)
        }
        if panel.runModal() == .OK, let url = panel.url {
            settingsStore.settings.outputFolder = url.path
            log.append("Output folder set to \(url.path)")
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(SettingsStore())
        .environmentObject(USBMonitor())
}
