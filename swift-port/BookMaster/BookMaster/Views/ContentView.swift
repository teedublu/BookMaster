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
    @State private var checkedContent: MasterContent?

    private let availableTests = ["Silence", "Loudness", "Metadata", "Frames", "Speed"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                inputFolderSection
                optionsSection
                metadataSection
                actionsSection
                HStack(alignment: .top, spacing: 16) {
                    webcamPanel
                    usbDrivesPanel
                    usbChecksPanel
                }
                logSection
            }
            .padding(16)
        }
        .onAppear {
            log.append("Loaded settings from \(settingsStore.settingsFilePath)")
            log.append("Config: bit_rate=\(ConfigStore.shared.encoding.bitRate) max_drive_size=\(ConfigStore.shared.maxDriveSize)")
        }
        .onChange(of: settingsStore.settings) { _ in
            settingsStore.save()
        }
        .onChange(of: usbMonitor.drives) { newDrives in
            let currentIDs = Set(newDrives.map(\.id))
            for drive in newDrives where !loggedDriveIDs.contains(drive.id) {
                log.append("USB candidate appeared: \(drive.bsdName) (\(drive.volumeName ?? "unmounted"), \(ByteCountFormatter.string(fromByteCount: drive.sizeBytes, countStyle: .file)))")
            }
            for id in loggedDriveIDs where !currentIDs.contains(id) {
                log.append("USB candidate removed: \(id)")
            }
            loggedDriveIDs = currentIDs
            if let selectedDriveID, !currentIDs.contains(selectedDriveID) {
                self.selectedDriveID = nil
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
            checkedContent = nil
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

    // MARK: Row 8 — Actions

    private var actionsSection: some View {
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
                Button("Check Master") {
                    checkMaster()
                }
                .disabled(selectedDrive == nil)
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

    private func checkMaster() {
        guard let drive = selectedDrive, let mountPath = drive.mountPath else {
            log.append("No mounted drive selected to check.")
            return
        }
        log.append("Checking master at \(mountPath)\u{2026}")
        let content = MasterReader.read(mountPath: URL(fileURLWithPath: mountPath))
        checkedContent = content
        if content.isbn == nil {
            log.append("No master found on \(drive.bsdName) (missing bookInfo/id.txt).")
        } else {
            let checksumStatus = content.checksumMatches == true ? "OK" : (content.checksumMatches == false ? "MISMATCH" : "unknown")
            log.append("Master found: ISBN=\(content.isbn ?? "-") files=\(content.fileCount.map(String.init) ?? "-") checksum=\(checksumStatus)")
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
                Group {
                    detailRow("Content", checkedContent == nil ? "-" : (checkedContent?.isbn == nil ? "Invalid" : "Valid"))
                    detailRow("ISBN", checkedContent?.isbn ?? "-")
                    detailRow("Files", checkedContent?.fileCount.map(String.init) ?? "-")
                    detailRow("Checksum", checkedContent?.checksumMatches.map { $0 ? "OK" : "MISMATCH" } ?? "-")
                }
            }
            .frame(width: 240, alignment: .leading)
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
