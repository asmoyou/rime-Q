// Adapted from scholay/rimes, InputSourceInstaller.swift.
// Copyright (c) 2026 scholay; MIT license retained at third_party/rimes/LICENSE.
// Changes: Rime Q CLI namespace and optional selection after enabling.

import Cocoa
import Carbon
import Darwin
import Foundation

/// TIS source references are process-local snapshots.  Keep every mutating
/// step in a short-lived process, then verify it from another process so an
/// install never makes the child mode race its parent or reuses a stale ref.
enum InputSourceInstallPhase: String, CaseIterable {
    case validateBundle = "--rimeq-tis-validate-bundle"
    case register = "--rimeq-tis-register"
    case verifyInstalled = "--rimeq-tis-verify-installed"
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

private enum InputSourceInstallExit {
    static let success: Int32 = 0
    static let failed: Int32 = 1
    static let retryable: Int32 = 75 // EX_TEMPFAIL
}

private struct InputSourceInstallIdentity {
    let bundleID: String
    let modeID: String

    static func load() -> InputSourceInstallIdentity? {
        guard let info = Bundle.main.infoDictionary,
              let bundleID = Bundle.main.bundleIdentifier,
              info["TISInputSourceID"] as? String == bundleID,
              let component = info["ComponentInputModeDict"]
                as? [String: Any],
              let visibleModes = component["tsVisibleInputModeOrderedArrayKey"]
                as? [String],
              visibleModes.count == 1,
              let modeID = visibleModes.first,
              let modeList = component["tsInputModeListKey"]
                as? [String: Any],
              let modeEntry = modeList[modeID] as? [String: Any],
              modeEntry["TISInputSourceID"] as? String == modeID,
              modeID.hasPrefix(bundleID + ".") else {
            print("install: invalid bundle/input-mode metadata")
            return nil
        }
        return InputSourceInstallIdentity(bundleID: bundleID, modeID: modeID)
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
    let filter = [kTISPropertyBundleID as String: identity.bundleID] as CFDictionary
    guard let cf = TISCreateInputSourceList(filter, includeAllInstalled)?
            .takeRetainedValue(),
          let sources = cf as? [TISInputSource] else {
        print("install: TIS roster unavailable all=\(includeAllInstalled)")
        return nil
    }

    var parent: [InputSourceInstallMatch] = []
    var mode: [InputSourceInstallMatch] = []
    var unexpected: [InputSourceInstallMatch] = []
    for source in sources {
        guard let metadata = inputSourceMetadata(source) else { continue }
        let match = InputSourceInstallMatch(
            source: source,
            metadata: metadata,
            iconURL: installerTISURLProperty(source, kTISPropertyIconImageURL)
        )
        switch metadata.sourceID {
        case identity.bundleID:
            parent.append(match)
        case identity.modeID:
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
    if roster.parent.count > 1 || roster.mode.count > 1 {
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
                        identity: InputSourceInstallIdentity)
    -> InputSourceInstallMatch? {
    guard roster.mode.count == 1,
          let mode = roster.mode.first,
          InputSourceInstallRules.isMode(
            mode.metadata,
            bundleID: identity.bundleID,
            modeID: identity.modeID
          ) else {
        return nil
    }
    return mode
}

private func runInputSourceInstallPhase(_ phase: InputSourceInstallPhase) -> Int32 {
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
            && uniqueMode(in: roster, identity: identity) != nil
            ? InputSourceInstallExit.success
            : InputSourceInstallExit.retryable

    case .enableParent:
        guard let roster = inputSourceRoster(
                identity: identity,
                includeAllInstalled: true
              ),
              let parent = uniqueParent(in: roster, identity: identity) else {
            print("install: cannot resolve a unique parent to enable")
            return InputSourceInstallExit.retryable
        }
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
              let mode = uniqueMode(in: installed, identity: identity) else {
            print("install: parent not ready or child mode is ambiguous")
            return InputSourceInstallExit.retryable
        }
        let status = TISEnableInputSource(mode.source)
        print(
            "install: enable mode=\(status)"
                + " reportedBefore=\(describe(mode.metadata.enabled))"
                + " \(identity.modeID)"
        )
        return status == noErr
            ? InputSourceInstallExit.success
            : InputSourceInstallExit.retryable

    case .verifyMode:
        guard let roster = inputSourceRoster(
                identity: identity,
                includeAllInstalled: false
              ) else {
            return InputSourceInstallExit.retryable
        }
        logRoster(roster, label: "enabled-mode", identity: identity)
        let parent = uniqueParent(in: roster, identity: identity)
        let mode = uniqueMode(in: roster, identity: identity)
        let ready = parent != nil && mode != nil
            && InputSourceInstallRules.modeReachedEnabledRoster(
                roster.mode.count
            )
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
    deadlineUptime: TimeInterval
) -> Bool {
    for (index, delay) in InputSourceInstallRules.retryDelays.enumerated() {
        var remaining = deadlineUptime - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else {
            print("install: total activation budget expired at \(label)")
            return false
        }
        let actionStatus = runInputSourceInstallSubprocess(
            action,
            timeout: min(InputSourceInstallRules.subprocessTimeout, remaining)
        )
        if delay > 0 {
            remaining = deadlineUptime - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else {
                print("install: total activation budget expired at \(label)")
                return false
            }
            Thread.sleep(forTimeInterval: min(delay, remaining))
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
func installInputSource(selectAfterEnabling: Bool = false) -> Bool {
    guard InputSourceInstallIdentity.load() != nil else { return false }
    let deadlineUptime = ProcessInfo.processInfo.systemUptime
        + InputSourceInstallRules.totalInstallBudget

    guard convergeInputSourceInstallBoundary(
            "registered",
            action: .register,
            verify: .verifyInstalled,
            deadlineUptime: deadlineUptime
          ),
          convergeInputSourceInstallBoundary(
            "parent-enabled",
            action: .enableParent,
            verify: .verifyParent,
            deadlineUptime: deadlineUptime
          ),
          convergeInputSourceInstallBoundary(
            "mode-enabled",
            action: .enableMode,
            verify: .verifyMode,
            deadlineUptime: deadlineUptime
          ) else {
        return false
    }

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
