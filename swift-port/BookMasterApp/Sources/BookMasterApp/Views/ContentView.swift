import SwiftUI
import AppKit
import BookMasterCore

/// Phase 1 app shell: reproduces every field/control from
/// src/ui/main_window.py's create_widgets(), backed by real Codable
/// settings persistence, but with NO disk/encoding/USB logic wired in
/// yet (that's Phase 2 onward). Buttons that would trigger real work in
/// the Python app just log a "(stub)" line here.
struct ContentView: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var usbMonitor: USBMonitor
    @StateObject private var log = LogStore()
    @State private var selectedDriveID: String?
    @State private var loggedDriveIDs: Set<String> = []

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
                Button("Create Master") {
                    log.append("Create Master (stub — Phase 2-4 wire real encode/image/write)")
                }
                .keyboardShortcut(.defaultAction)
                Toggle("Write image to block", isOn: $settingsStore.settings.writeImageMode)
                Spacer()
                Button("Check Master") {
                    log.append("Check Master (stub — Phase 2/7 wire real drive checks)")
                }
            }
        }
    }

    // MARK: Row 9 — Webcam / USB Drives / USB Checks panels

    private var webcamPanel: some View {
        GroupBox("Webcam") {
            VStack {
                Rectangle()
                    .fill(Color.gray.opacity(0.15))
                    .frame(width: 220, height: 160)
                    .overlay(Text("Camera not wired yet\n(Phase 5 — Vision/AVFoundation)")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .font(.caption))
            }
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
                Text("Content/SKU/ISBN validity reading is Phase 7 work,\nnot wired up yet.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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
