import Foundation

/// Tests every mutant inside one test launch per test target, instead of launching the tests once per
/// mutant. Each target selected with `-only-testing:` must contain the runner test named by the
/// configuration's `inProcessRunner`. Muter starts that test with the mutant identifiers in
/// `MUTER_MUTANTS` and the selected suites in `MUTER_TEST_FILTER` (both comma separated); the test
/// switches each mutant on through its environment variable, runs the suites, and prints
/// `MUTER_MUTANT_STARTED <id>` and `MUTER_MUTANT_FINISHED <id> <exit code>`.
///
/// When a launch ends early, the mutant that was running crashed the tests and counts as killed. When no
/// line arrives within the mutation test timeout, the launch is stopped and that mutant counts as timed
/// out. Either way, a new launch carries on with the remaining mutants.
struct InProcessMutationRunner {
    let configuration: MuterConfiguration
    let runnerName: String
    let testRunFileName: String
    let workingDirectory: URL

    /// Run first in every target, without switching any mutant on: the suites must pass in process
    /// before any mutant can be judged.
    static let baselineIdentifier = "MUTER_IN_PROCESS_BASELINE"
    private static let defaultTimeout: TimeInterval = 60
    private static let killGracePeriod: TimeInterval = 5
    private static let pollInterval: UInt64 = 250_000_000

    struct Result {
        let outcomes: [String: TestSuiteOutcome]
        let logs: [String: String]
    }

    init(
        configuration: MuterConfiguration,
        runnerName: String,
        testRunFileName: String,
        workingDirectory: URL
    ) {
        self.configuration = configuration
        self.runnerName = runnerName
        self.testRunFileName = testRunFileName
        self.workingDirectory = workingDirectory
    }

    func run(mutantIdentifiers: [String]) async throws -> Result {
        let selection = configuration.testSelectionByTarget
        guard !selection.isEmpty else {
            throw MuterError.literal(
                reason: "inProcessRunner needs the tests to run as -only-testing:<Target>/<Suite> arguments."
            )
        }

        var outcomes: [String: TestSuiteOutcome] = [:]
        var logs: [String: String] = [:]
        for (target, suites) in selection.sorted(by: { $0.key < $1.key }) {
            let targetResult = try await run(
                mutantIdentifiers: mutantIdentifiers,
                target: target,
                suites: suites
            )
            for (identifier, outcome) in targetResult.outcomes {
                outcomes[identifier] = Self.combine(outcomes[identifier], outcome)
            }
            for (identifier, log) in targetResult.logs {
                logs[identifier, default: ""] += log
            }
        }
        return Result(outcomes: outcomes, logs: logs)
    }

    /// A mutant is killed if the tests of any target catch it.
    static func combine(_ current: TestSuiteOutcome?, _ new: TestSuiteOutcome) -> TestSuiteOutcome {
        guard let current else {
            return new
        }

        let killing: Set<TestSuiteOutcome> = [.failed, .runtimeError]
        if killing.contains(current) || killing.contains(new) {
            return killing.contains(current) ? current : new
        }
        return current == .timeout || new == .timeout ? .timeout : current
    }

    private func run(
        mutantIdentifiers: [String],
        target: String,
        suites: [String]
    ) async throws -> Result {
        var outcomes: [String: TestSuiteOutcome] = [:]
        var logs: [String: String] = [:]
        var remaining = [Self.baselineIdentifier] + mutantIdentifiers
        var launch = 0

        while !remaining.isEmpty {
            launch += 1
            let logURL = workingDirectory.appendingPathComponent("in-process \(target) \(launch).log")
            let (log, timedOut) = try await launchTests(
                target: target,
                suites: suites,
                mutants: remaining,
                logURL: logURL
            )
            let progress = InProcessRunnerLog(log)

            guard progress.hasStarted else {
                throw MuterError.literal(reason: """
                The in-process runner \(target)/\(runnerName) did not start. Check that the target contains \
                that test. Log: \(logURL.path)
                """)
            }

            for (identifier, exitCode) in progress.finished {
                if identifier == Self.baselineIdentifier {
                    guard exitCode == 0 else {
                        throw MuterError.literal(reason: """
                        The tests of \(target) failed in process before any mutant was switched on. \
                        Log: \(logURL.path)
                        """)
                    }
                    continue
                }
                guard exitCode == 0 || exitCode == 1 else {
                    throw MuterError.literal(reason: """
                    The in-process runner of \(target) ran no test (exit code \(exitCode)). Check the \
                    -only-testing suites. Log: \(logURL.path)
                    """)
                }
                outcomes[identifier] = exitCode == 0 ? .passed : .failed
                logs[identifier] = progress.excerpt(for: identifier)
            }

            var handled = Set(progress.finished.map { $0.identifier })
            if let interrupted = progress.unfinished {
                guard interrupted != Self.baselineIdentifier else {
                    throw MuterError.literal(reason: """
                    The tests of \(target) \(timedOut ? "timed out" : "crashed") in process before any \
                    mutant was switched on. Log: \(logURL.path)
                    """)
                }
                outcomes[interrupted] = timedOut ? .timeout : .runtimeError
                logs[interrupted] = progress.excerpt(for: interrupted)
                handled.insert(interrupted)
            }
            remaining.removeAll { handled.contains($0) }
        }

        return Result(outcomes: outcomes, logs: logs)
    }

    /// Runs the runner test once and returns its output, and whether it was stopped for going silent.
    private func launchTests(
        target: String,
        suites: [String],
        mutants: [String],
        logURL: URL
    ) async throws -> (log: String, timedOut: Bool) {
        try Data().write(to: logURL)
        let logHandle = try FileHandle(forWritingTo: logURL)
        defer { try? logHandle.close() }

        // Foundation's Process rather than the injected one: the runner needs isRunning and the process
        // identifier, to stop a launch that went silent.
        let testProcess = Foundation.Process()
        testProcess.executableURL = URL(fileURLWithPath: configuration.testCommandExecutable)
        testProcess.arguments = configuration.inProcessTestArguments(
            testRunFileName: testRunFileName,
            runnerTest: "\(target)/\(runnerName)"
        )
        var environment = ProcessInfo.processInfo.environment
        environment[isMuterRunningKey] = isMuterRunningValue
        // xcodebuild hands TEST_RUNNER_-prefixed variables to the tests, without the prefix.
        environment["TEST_RUNNER_MUTER_MUTANTS"] = mutants.joined(separator: ",")
        environment["TEST_RUNNER_MUTER_TEST_FILTER"] = suites.joined(separator: ",")
        testProcess.environment = environment
        testProcess.standardOutput = logHandle
        testProcess.standardError = logHandle
        testProcess.currentDirectoryURL = workingDirectory

        try testProcess.run()

        let timeout = configuration.testSuiteTimeout ?? Self.defaultTimeout
        var lastProgressCount = 0
        var lastProgressDate = Date()
        var timedOut = false
        while testProcess.isRunning {
            try? await Task.sleep(nanoseconds: Self.pollInterval)
            let progressCount = InProcessRunnerLog((try? String(contentsOf: logURL)) ?? "").progressLineCount
            if progressCount != lastProgressCount {
                lastProgressCount = progressCount
                lastProgressDate = Date()
            } else if Date().timeIntervalSince(lastProgressDate) > timeout {
                timedOut = true
                await stop(testProcess)
                break
            }
        }

        return ((try? String(contentsOf: logURL)) ?? "", timedOut)
    }

    /// xcodebuild can take minutes to honour an interrupt, so it is killed after a grace period.
    private func stop(_ testProcess: Foundation.Process) async {
        testProcess.interrupt()
        let deadline = Date().addingTimeInterval(Self.killGracePeriod)
        while testProcess.isRunning, Date() < deadline {
            try? await Task.sleep(nanoseconds: Self.pollInterval)
        }
        if testProcess.isRunning {
            kill(testProcess.processIdentifier, SIGKILL)
            testProcess.waitUntilExit()
        }
    }
}

/// The progress lines the in-process runner test prints.
struct InProcessRunnerLog {
    private static let startedPrefix = "MUTER_MUTANT_STARTED "
    private static let finishedPrefix = "MUTER_MUTANT_FINISHED "

    private let lines: [Substring]
    let started: [String]
    let finished: [(identifier: String, exitCode: Int32)]

    init(_ log: String) {
        lines = log.split(separator: "\n", omittingEmptySubsequences: false)
        var started: [String] = []
        var finished: [(identifier: String, exitCode: Int32)] = []
        for line in lines {
            if line.hasPrefix(Self.startedPrefix) {
                started.append(String(line.dropFirst(Self.startedPrefix.count)).trimmingCharacters(in: .whitespaces))
            } else if line.hasPrefix(Self.finishedPrefix) {
                let fields = line.dropFirst(Self.finishedPrefix.count).split(separator: " ")
                if fields.count == 2, let exitCode = Int32(fields[1]) {
                    finished.append((String(fields[0]), exitCode))
                }
            }
        }
        self.started = started
        self.finished = finished
    }

    var hasStarted: Bool {
        !started.isEmpty
    }

    var progressLineCount: Int {
        started.count + finished.count
    }

    /// The mutant that was running when the launch ended, if any.
    var unfinished: String? {
        guard let last = started.last, !finished.contains(where: { $0.identifier == last }) else {
            return nil
        }
        return last
    }

    /// The output between a mutant's started line and its finished line, or the end of the log.
    func excerpt(for identifier: String) -> String {
        guard let start = lines.firstIndex(of: Substring(Self.startedPrefix + identifier)) else {
            return ""
        }
        let end = lines[start...].firstIndex { $0.hasPrefix(Self.finishedPrefix + identifier + " ") } ?? lines.endIndex - 1
        return lines[start...end].joined(separator: "\n")
    }
}
