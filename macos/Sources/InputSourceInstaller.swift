// Adapted from scholay/rimes, InputSourceInstaller.swift.
// Copyright (c) 2026 scholay; MIT license retained at third_party/rimes/LICENSE.
// Changes: Rime Q CLI namespace and optional selection after enabling.

import Cocoa
import Carbon
import Darwin
import Foundation

/// Mutations run in the LaunchServices-launched user application. Verification
/// uses short-lived processes, whose TIS snapshots are independent of the caller.
enum InputSourceInstallPhase: String, CaseIterable {
    case validateBundle = "--rimeq-tis-validate-bundle"
    case register = "--rimeq-tis-register"
    case verifyInstalled = "--rimeq-tis-verify-installed"
    case leaveSource = "--rimeq-tis-leave-source"
    case verifyLeft = "--rimeq-tis-verify-left"
    case disableMode = "--rimeq-tis-disable-mode"
    case verifyModeDisabled = "--rimeq-tis-verify-mode-disabled"
    case disableParent = "--rimeq-tis-disable-parent"
    case verifyParentDisabled = "--rimeq-tis-verify-parent-disabled"
    case enableParent = "--rimeq-tis-enable-parent"
    case verifyParent = "--rimeq-tis-verify-parent"
    case enableMode = "--rimeq-tis-enable-mode"
    case verifyMode = "--rimeq-tis-verify-mode"
    case selectMode = "--rimeq-tis-select-mode"
    case verifySelected = "--rimeq-tis-verify-selected"
}

struct InputSourceInstallMetadata: Equatable {
    let sourceID: String
    let bundleID: String
    let sourceType: String?
    let category: String?
    let enabled: Bool?
    let enableCapable: Bool?
    let selectCapable: Bool?
    let asciiCapable: Bool?
}

enum InputSourceInstallRules {
    static func validConnectionName(_ name: String?, bundleID: String) -> Bool {
        name == bundleID + "_Connection"
    }
    /// Roughly eleven seconds per convergence boundary. There is deliberately
    /// no claim that Apple completes TIS propagation within this interval: a
    /// timeout means "defer to login/session refresh", not "bundle install
    /// failed".
    static let retryDelays: [TimeInterval] = [
        0, 0.10, 0.25, 0.50, 1.0, 2.0, 3.0, 4.0,
    ]
    static let subprocessTimeout: TimeInterval = 3
    static let totalInstallBudget: TimeInterval = 90

    static func isParent(_ metadata: InputSourceInstallMetadata,
                         parentID: String) -> Bool {
        guard metadata.sourceID == parentID,
              metadata.bundleID == parentID,
              metadata.sourceType == nil
                || metadata.sourceType == kTISTypeKeyboardInputMethodModeEnabled as String,
              metadata.category == nil
                || metadata.category == kTISCategoryKeyboardInputSource as String,
              metadata.enableCapable != false,
              metadata.selectCapable != true else {
            return false
        }
        return true
    }

    static func isMode(_ metadata: InputSourceInstallMetadata,
                       bundleID: String,
                       modeID: String) -> Bool {
        guard metadata.sourceID == modeID,
              metadata.bundleID == bundleID,
              metadata.sourceType == nil
                || metadata.sourceType == kTISTypeKeyboardInputMode as String,
              metadata.category == nil
                || metadata.category == kTISCategoryKeyboardInputSource as String,
              metadata.enableCapable != false,
              metadata.selectCapable != false else {
            return false
        }
        return true
    }

    /// Never use an all-installed object's possibly stale IsEnabled property as
    /// the fence before enabling the child. The public dependency is satisfied
    /// only after a fresh enabled-only process sees the unique parent.
    static func parentDependencySatisfied(parentInEnabledRoster: Bool) -> Bool {
        parentInEnabledRoster
    }

    /// ASCII capability is intentionally not part of this predicate. It is a
    /// product metadata diagnostic, not an enable/select precondition, and the
    /// public TIS contract permits properties to be absent for some sources.
    static func modeReachedEnabledRoster(_ modeCount: Int) -> Bool {
        modeCount == 1
    }
}

/// Retry a failed mutation; once accepted, only poll its independent verification.
struct InputSourceInstallAttempt {
    private(set) var status: Int32 = 75
    mutating func run(_ action: () -> Int32) -> Int32 {
        if status != 0 { status = action() }
        return status
    }
}

private enum InputSourceInstallExit {
    static let success: Int32 = 0
    static let failed: Int32 = 1
    static let retryable: Int32 = 75 // EX_TEMPFAIL
}

private struct InputSourceInstallIdentity {
    let bundleID: String
    let modeIDs: [String]
    var modeID: String { modeIDs[0] }
    var cleanupModeIDs: [String] { modeIDs + InputMode.retiredIdentifiers }

    static func load() -> InputSourceInstallIdentity? {
        guard let info = Bundle.main.infoDictionary,
              let bundleID = Bundle.main.bundleIdentifier,
              InputSourceInstallRules.validConnectionName(info["InputMethodConnectionName"] as? String, bundleID: bundleID),
              info["TISInputSourceID"] as? String == bundleID,
              let component = info["ComponentInputModeDict"]
                as? [String: Any],
              let visibleModes = component["tsVisibleInputModeOrderedArrayKey"]
                as? [String],
              visibleModes == [InputMode.chinese],
              let modeList = component["tsInputModeListKey"]
                as? [String: Any],
              Set(modeList.keys) == Set(InputMode.identifiers),
              InputMode.identifiers.allSatisfy({ identifier in
                  guard let entry = modeList[identifier] as? [String: Any] else { return false }
                  return entry["TISInputSourceID"] as? String == identifier
                      && identifier.hasPrefix(bundleID + ".")
              }) else {
            print("install: invalid bundle/input-mode metadata")
            return nil
        }
        return InputSourceInstallIdentity(bundleID: bundleID, modeIDs: InputMode.identifiers)
    }
}

private struct InputSourceInstallMatch {
    let source: TISInputSource
    let metadata: InputSourceInstallMetadata
    let iconURL: String?
}

private struct InputSourceInstallRoster {
    let parent: [InputSourceInstallMatch]
    let mode: [InputSourceInstallMatch]
    let unexpected: [InputSourceInstallMatch]
}

private func installerTISStringProperty(_ source: TISInputSource,
                                        _ key: CFString) -> String? {
    guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
    return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
}

private func installerTISBoolProperty(_ source: TISInputSource,
                                      _ key: CFString) -> Bool? {
    guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
    return Unmanaged<NSNumber>.fromOpaque(pointer).takeUnretainedValue().boolValue
}

private func installerTISURLProperty(_ source: TISInputSource,
                                     _ key: CFString) -> String? {
    guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
    let url = Unmanaged<CFURL>.fromOpaque(pointer).takeUnretainedValue() as URL
    return url.path
}

private func inputSourceMetadata(_ source: TISInputSource)
    -> InputSourceInstallMetadata? {
    guard let sourceID = installerTISStringProperty(
            source,
            kTISPropertyInputSourceID
          ),
          let bundleID = installerTISStringProperty(
            source,
            kTISPropertyBundleID
          ) else {
        return nil
    }
    return InputSourceInstallMetadata(
        sourceID: sourceID,
        bundleID: bundleID,
        sourceType: installerTISStringProperty(
            source,
            kTISPropertyInputSourceType
        ),
        category: installerTISStringProperty(
            source,
            kTISPropertyInputSourceCategory
        ),
        enabled: installerTISBoolProperty(
            source,
            kTISPropertyInputSourceIsEnabled
        ),
        enableCapable: installerTISBoolProperty(
            source,
            kTISPropertyInputSourceIsEnableCapable
        ),
        selectCapable: installerTISBoolProperty(
            source,
            kTISPropertyInputSourceIsSelectCapable
        ),
        asciiCapable: installerTISBoolProperty(
            source,
            kTISPropertyInputSourceIsASCIICapable
        )
    )
}

private func inputSourceRoster(identity: InputSourceInstallIdentity,
                               includeAllInstalled: Bool)
    -> InputSourceInstallRoster? {
    // A filtered TIS query returns nil for no matches. Query the complete
    // roster so absence can be distinguished from an unavailable service.
    guard let cf = TISCreateInputSourceList(nil, includeAllInstalled)?
            .takeRetainedValue(),
          let sources = cf as? [TISInputSource] else {
        print("install: TIS roster unavailable all=\(includeAllInstalled)")
        return nil
    }

    var parent: [InputSourceInstallMatch] = []
    var mode: [InputSourceInstallMatch] = []
    var unexpected: [InputSourceInstallMatch] = []
    for source in sources {
        guard let metadata = inputSourceMetadata(source), metadata.bundleID == identity.bundleID else { continue }
        let match = InputSourceInstallMatch(
            source: source,
            metadata: metadata,
            iconURL: installerTISURLProperty(source, kTISPropertyIconImageURL)
        )
        switch metadata.sourceID {
        case identity.bundleID:
            parent.append(match)
        case let identifier where identity.cleanupModeIDs.contains(identifier):
            mode.append(match)
        default:
            unexpected.append(match)
        }
    }
    return InputSourceInstallRoster(
        parent: parent,
        mode: mode,
        unexpected: unexpected
    )
}

private func describe(_ value: Bool?) -> String {
    value.map(String.init) ?? "nil"
}

private func logRoster(_ roster: InputSourceInstallRoster,
                       label: String,
                       identity: InputSourceInstallIdentity) {
    func log(_ role: String, _ matches: [InputSourceInstallMatch]) {
        if matches.isEmpty {
            print("install: \(label) \(role)=missing")
            return
        }
        for (index, match) in matches.enumerated() {
            let metadata = match.metadata
            let sourceType = metadata.sourceType ?? "nil"
            let category = metadata.category ?? "nil"
            let iconURL = match.iconURL ?? "nil"
            print(
                "install: \(label) \(role)[\(index)]"
                    + " id=\(metadata.sourceID)"
                    + " type=\(sourceType)"
                    + " category=\(category)"
                    + " enabled=\(describe(metadata.enabled))"
                    + " enableCapable=\(describe(metadata.enableCapable))"
                    + " selectCapable=\(describe(metadata.selectCapable))"
                    + " ascii=\(describe(metadata.asciiCapable))"
                    + " icon=\(iconURL)"
            )
        }
    }
    log("parent", roster.parent)
    log("mode", roster.mode)
    if !roster.unexpected.isEmpty {
        let ids = roster.unexpected.map(\.metadata.sourceID).joined(separator: ",")
        print("install: \(label) unexpected bundle sources=\(ids)")
    }
    if roster.parent.count > 1 || Dictionary(grouping: roster.mode, by: \.metadata.sourceID).values.contains(where: { $0.count > 1 }) {
        print(
            "install: \(label) ambiguous registrations"
                + " parent=\(roster.parent.count) mode=\(roster.mode.count)"
                + " expected=\(identity.bundleID),\(identity.modeID)"
        )
    }
}

private func uniqueParent(in roster: InputSourceInstallRoster,
                          identity: InputSourceInstallIdentity)
    -> InputSourceInstallMatch? {
    guard roster.parent.count == 1,
          let parent = roster.parent.first,
          InputSourceInstallRules.isParent(
            parent.metadata,
            parentID: identity.bundleID
          ) else {
        return nil
    }
    return parent
}

private func uniqueMode(in roster: InputSourceInstallRoster,
                        identity: InputSourceInstallIdentity, identifier: String? = nil)
    -> InputSourceInstallMatch? {
    let modeID = identifier ?? identity.modeID
    let matches = roster.mode.filter { $0.metadata.sourceID == modeID }
    guard matches.count == 1,
          let mode = matches.first,
          InputSourceInstallRules.isMode(
            mode.metadata,
            bundleID: identity.bundleID,
            modeID: modeID
          ) else {
        return nil
    }
    return mode
}

private func allModes(in roster: InputSourceInstallRoster,
                      identity: InputSourceInstallIdentity) -> [InputSourceInstallMatch]? {
    let modes = identity.modeIDs.compactMap { uniqueMode(in: roster, identity: identity, identifier: $0) }
    return modes.count == identity.modeIDs.count ? modes : nil
}

private func runInputSourceInstallPhase(_ phase: InputSourceInstallPhase, forceEnable: Bool = false) -> Int32 {
    guard let identity = InputSourceInstallIdentity.load() else {
        return InputSourceInstallExit.failed
    }

    switch phase {
    case .validateBundle:
        print(
            "install: bundle metadata valid"
                + " parent=\(identity.bundleID) mode=\(identity.modeID)"
        )
        return InputSourceInstallExit.success

    case .register:
        let status = TISRegisterInputSource(Bundle.main.bundleURL as CFURL)
        print("install: register \(Bundle.main.bundleURL.path) -> \(status)")
        return status == noErr
            ? InputSourceInstallExit.success
            : InputSourceInstallExit.retryable

    case .verifyInstalled:
        guard let roster = inputSourceRoster(
                identity: identity,
                includeAllInstalled: true
              ) else {
            return InputSourceInstallExit.retryable
        }
        logRoster(roster, label: "installed", identity: identity)
        return uniqueParent(in: roster, identity: identity) != nil
            && allModes(in: roster, identity: identity) != nil
            ? InputSourceInstallExit.success
            : InputSourceInstallExit.retryable

    case .leaveSource, .verifyLeft:
        guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return InputSourceInstallExit.retryable }
        let isOurs = installerTISStringProperty(current, kTISPropertyBundleID) == identity.bundleID
        if !isOurs { return InputSourceInstallExit.success }
        if phase == .verifyLeft { return InputSourceInstallExit.retryable }
        guard let all = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else { return InputSourceInstallExit.retryable }
        let fallbacks = all.filter {
            installerTISStringProperty($0, kTISPropertyBundleID) != identity.bundleID
                && installerTISBoolProperty($0, kTISPropertyInputSourceIsSelectCapable) == true
                && installerTISBoolProperty($0, kTISPropertyInputSourceIsASCIICapable) == true
        }
        guard let fallback = fallbacks.first(where: { installerTISStringProperty($0, kTISPropertyInputSourceID) == "com.apple.keylayout.US" }) ?? fallbacks.first else {
            return InputSourceInstallExit.retryable
        }
        let result = TISSelectInputSource(fallback)
        print("install: leave own input source before refresh=\(result)")
        return result == noErr ? InputSourceInstallExit.success : InputSourceInstallExit.retryable

    case .disableMode, .disableParent:
        guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              installerTISStringProperty(current, kTISPropertyBundleID) != identity.bundleID,
              let roster = inputSourceRoster(identity: identity, includeAllInstalled: true) else { return InputSourceInstallExit.retryable }
        let matches = phase == .disableMode ? roster.mode : roster.parent
        if matches.isEmpty { return InputSourceInstallExit.success }
        // Include the retired Latin mode when repairing the dual-mode preview.
        // Never enable it or require it for the current single-source bundle.
        for match in matches {
            let unique = phase == .disableMode
                ? uniqueMode(in: roster, identity: identity, identifier: match.metadata.sourceID)
                : uniqueParent(in: roster, identity: identity)
            guard unique != nil else { return InputSourceInstallExit.failed }
            if match.metadata.enabled == false { continue }
            let result = TISDisableInputSource(match.source)
            print("install: refresh disable=\(result) id=\(match.metadata.sourceID)")
            if result != noErr { return InputSourceInstallExit.retryable }
        }
        return InputSourceInstallExit.success

    case .verifyModeDisabled, .verifyParentDisabled:
        guard let roster = inputSourceRoster(identity: identity, includeAllInstalled: false) else { return InputSourceInstallExit.retryable }
        let absent = phase == .verifyModeDisabled ? roster.mode.isEmpty : roster.parent.isEmpty
        print("install: refresh disabled boundary=\(phase.rawValue) ready=\(absent)")
        return absent ? InputSourceInstallExit.success : InputSourceInstallExit.retryable

    case .enableParent:
        guard let roster = inputSourceRoster(
                identity: identity,
                includeAllInstalled: true
              ),
              let parent = uniqueParent(in: roster, identity: identity) else {
            print("install: cannot resolve a unique parent to enable")
            return InputSourceInstallExit.retryable
        }
        if !forceEnable, let enabled = inputSourceRoster(identity: identity, includeAllInstalled: false),
           uniqueParent(in: enabled, identity: identity) != nil { return InputSourceInstallExit.success }
        let status = TISEnableInputSource(parent.source)
        print(
            "install: enable parent=\(status)"
                + " reportedBefore=\(describe(parent.metadata.enabled))"
                + " \(identity.bundleID)"
        )
        return status == noErr
            ? InputSourceInstallExit.success
            : InputSourceInstallExit.retryable

    case .verifyParent:
        guard let installed = inputSourceRoster(
                identity: identity,
                includeAllInstalled: true
              ),
              let enabled = inputSourceRoster(
                identity: identity,
                includeAllInstalled: false
              ) else {
            return InputSourceInstallExit.retryable
        }
        logRoster(enabled, label: "enabled-parent", identity: identity)
        let installedParent = uniqueParent(in: installed, identity: identity)
        let enabledParent = uniqueParent(in: enabled, identity: identity)
        let ready = InputSourceInstallRules.parentDependencySatisfied(
            parentInEnabledRoster: enabledParent != nil
        )
        print(
            "install: parent dependency ready=\(ready)"
                + " installedReported=\(describe(installedParent?.metadata.enabled))"
        )
        return ready
            ? InputSourceInstallExit.success
            : InputSourceInstallExit.retryable

    case .enableMode:
        guard let installed = inputSourceRoster(
                identity: identity,
                includeAllInstalled: true
              ),
              let enabled = inputSourceRoster(
                identity: identity,
                includeAllInstalled: false
              ),
              uniqueParent(in: installed, identity: identity) != nil,
              InputSourceInstallRules.parentDependencySatisfied(
                parentInEnabledRoster: uniqueParent(
                    in: enabled,
                    identity: identity
                ) != nil
              ),
              let modes = allModes(in: installed, identity: identity) else {
            print("install: parent not ready or child mode is ambiguous")
            return InputSourceInstallExit.retryable
        }
        for mode in modes {
            let identifier = mode.metadata.sourceID
            if !forceEnable, uniqueMode(in: enabled, identity: identity, identifier: identifier) != nil { continue }
            let status = TISEnableInputSource(mode.source)
            print("install: enable mode=\(status) id=\(identifier)")
            if status != noErr { return InputSourceInstallExit.retryable }
        }
        return InputSourceInstallExit.success

    case .verifyMode:
        guard let roster = inputSourceRoster(
                identity: identity,
                includeAllInstalled: false
              ) else {
            return InputSourceInstallExit.retryable
        }
        logRoster(roster, label: "enabled-mode", identity: identity)
        let parent = uniqueParent(in: roster, identity: identity)
        let ready = parent != nil && allModes(in: roster, identity: identity) != nil
        print(
            "install: child enabled roster ready=\(ready)"
                + " parentPresent=\(parent != nil)"
        )
        return ready
            ? InputSourceInstallExit.success
            : InputSourceInstallExit.retryable

    case .selectMode:
        guard let roster = inputSourceRoster(
                identity: identity,
                includeAllInstalled: false
              ),
              uniqueParent(in: roster, identity: identity) != nil,
              let mode = uniqueMode(in: roster, identity: identity) else {
            print("install: no fresh enabled parent/child pair to select")
            return InputSourceInstallExit.retryable
        }
        let status = TISSelectInputSource(mode.source)
        print("install: select=\(status) \(identity.modeID)")
        // Some recent macOS builds return paramErr while applying the change
        // asynchronously. A separate verifier is the authority.
        return status == noErr
            ? InputSourceInstallExit.success
            : InputSourceInstallExit.retryable

    case .verifySelected:
        guard let current = TISCopyCurrentKeyboardInputSource()?
                .takeRetainedValue() else {
            print("install: selected source unavailable")
            return InputSourceInstallExit.retryable
        }
        let currentID = installerTISStringProperty(
            current,
            kTISPropertyInputSourceID
        ) ?? "(unknown)"
        let selected = currentID == identity.modeID
        print("install: selected mode ready=\(selected) current=\(currentID)")
        return selected
            ? InputSourceInstallExit.success
            : InputSourceInstallExit.retryable
    }
}

/// Handles private phase arguments before AppKit/IMK/librime startup. A nil
/// return means the executable should continue with its ordinary command path.
func inputSourceInstallPhaseExitStatus(arguments: [String]) -> Int32? {
    let phases = InputSourceInstallPhase.allCases.filter {
        arguments.dropFirst().contains($0.rawValue)
    }
    guard !phases.isEmpty else { return nil }
    guard phases.count == 1, arguments.count == 2, let phase = phases.first else {
        print("install: invalid internal TIS phase arguments")
        return InputSourceInstallExit.failed
    }
    return runInputSourceInstallPhase(phase)
}

private func runInputSourceInstallSubprocess(
    _ phase: InputSourceInstallPhase,
    timeout: TimeInterval
) -> Int32 {
    guard let executableURL = Bundle.main.executableURL else {
        print("install: cannot locate installer executable")
        return InputSourceInstallExit.failed
    }
    let process = Process()
    let completed = DispatchSemaphore(value: 0)
    process.executableURL = executableURL
    process.currentDirectoryURL = URL(fileURLWithPath: "/")
    process.environment = ProcessInfo.processInfo.environment.filter { ["HOME", "USER", "LOGNAME", "TMPDIR", "PATH", "LANG"].contains($0.key) }
    process.arguments = [phase.rawValue]
    process.terminationHandler = { _ in completed.signal() }
    do {
        try process.run()
    } catch {
        print("install: cannot launch phase \(phase): \(error.localizedDescription)")
        return InputSourceInstallExit.failed
    }
    let boundedTimeout = max(0.05, timeout)
    let timeoutNanoseconds = Int(boundedTimeout * 1_000_000_000)
    if completed.wait(
        timeout: .now() + .nanoseconds(timeoutNanoseconds)
    ) == .timedOut {
        print("install: phase \(phase) exceeded \(boundedTimeout)s; terminating")
        if process.isRunning {
            process.terminate()
        }
        if completed.wait(timeout: .now() + .milliseconds(500)) == .timedOut,
           process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
            _ = completed.wait(timeout: .now() + .seconds(1))
        }
        return InputSourceInstallExit.retryable
    }
    guard process.terminationReason == .exit else {
        print("install: phase \(phase) terminated by signal")
        return InputSourceInstallExit.failed
    }
    return process.terminationStatus
}

private func convergeInputSourceInstallBoundary(
    _ label: String,
    action: InputSourceInstallPhase,
    verify: InputSourceInstallPhase,
    deadlineUptime: TimeInterval,
    forceEnable: Bool = false
) -> Bool {
    var attempt = InputSourceInstallAttempt()
    for (index, delay) in InputSourceInstallRules.retryDelays.enumerated() {
        var remaining = deadlineUptime - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else {
            print("install: total activation budget expired at \(label)")
            return false
        }
        // A successful mutation can take time to propagate. Do not repeat it
        // while waiting for independent verification (especially enable/disable).
        let actionStatus = attempt.run {
            InstallationDiagnostics.append("activation-action \(action.rawValue) caller=user-app forceEnable=\(forceEnable)")
            return runInputSourceInstallPhase(action, forceEnable: forceEnable)
        }
        if delay > 0 {
            remaining = deadlineUptime - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else {
                print("install: total activation budget expired at \(label)")
                return false
            }
            RunLoop.current.run(until: Date().addingTimeInterval(min(delay, remaining)))
        }
        remaining = deadlineUptime - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else {
            print("install: total activation budget expired at \(label)")
            return false
        }
        let verifyStatus = runInputSourceInstallSubprocess(
            verify,
            timeout: min(InputSourceInstallRules.subprocessTimeout, remaining)
        )
        print(
            "install: boundary=\(label) attempt=\(index + 1)"
                + " action=\(actionStatus) verify=\(verifyStatus)"
        )
        if verifyStatus == InputSourceInstallExit.success {
            return true
        }
    }
    print("install: boundary=\(label) pending system/session refresh")
    return false
}

/// Register, enable, and (when safe) select the shipped child input mode.
/// `false` means activation should be retried after a session refresh; package
/// installation must not reinterpret it as a corrupt payload.
func installInputSource(selectAfterEnabling: Bool = false, refreshEnabledSources: Bool = false) -> Bool {
    guard InputSourceInstallIdentity.load() != nil else { return false }
    let deadlineUptime = ProcessInfo.processInfo.systemUptime
        + InputSourceInstallRules.totalInstallBudget

    guard InputSourceActivation.run(refresh: refreshEnabledSources, boundary: { label, action, verify in
        let restoring = action == .enableParent || action == .enableMode
        let boundaryDeadline = refreshEnabledSources && !restoring ? deadlineUptime - 12 : deadlineUptime
        return convergeInputSourceInstallBoundary(label, action: action, verify: verify,
            deadlineUptime: boundaryDeadline, forceEnable: refreshEnabledSources && restoring)
    }) else { return false }

    if !selectAfterEnabling { return true }

    // The historical WeChat crash is in Apple's input-source HUD before our
    // controller runs. Enabling is complete; defer automatic selection.
    if NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        == "com.tencent.xinWeChat" {
        print("install: WeChat is frontmost; selection deferred")
        return true
    }

    let selected = convergeInputSourceInstallBoundary(
        "mode-selected",
        action: .selectMode,
        verify: .verifySelected,
        deadlineUptime: deadlineUptime
    )
    if !selected {
        print("install: mode is enabled; automatic selection remains best-effort")
    }
    return true
}

enum InputSourceActivation {
    /// An upgrade can retain enabled=true while the menu/client still uses an
    /// obsolete registration. Cycle our child then parent before re-enabling.
    /// Always attempt to restore enabled state if a refresh boundary fails.
    static func run(refresh: Bool, boundary: (String, InputSourceInstallPhase, InputSourceInstallPhase) -> Bool) -> Bool {
        guard boundary("registered", .register, .verifyInstalled) else { return false }
        var refreshed = true
        if refresh {
            refreshed = boundary("source-left", .leaveSource, .verifyLeft)
                && boundary("mode-disabled", .disableMode, .verifyModeDisabled)
                && boundary("parent-disabled", .disableParent, .verifyParentDisabled)
            // Registration and restoration still run after a partial failure.
            if !boundary("registered-after-refresh", .register, .verifyInstalled) { refreshed = false }
        }
        let parent = boundary("parent-enabled", .enableParent, .verifyParent)
        let mode = boundary("mode-enabled", .enableMode, .verifyMode)
        return refreshed && parent && mode
    }
}
