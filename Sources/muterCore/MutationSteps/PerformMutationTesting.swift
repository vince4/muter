import Foundation
import SwiftSyntax

struct PerformMutationTesting: MutationStep {
    @Dependency(\.ioDelegate)
    private var ioDelegate: MutationTestingIODelegate
    @Dependency(\.notificationCenter)
    private var notificationCenter: NotificationCenter
    @Dependency(\.fileManager)
    private var fileManager: FileSystemManager
    @Dependency(\.now)
    private var now: Now

    private let buildErrorsThreshold: Int = 5

    func run(
        with state: AnyMutationTestState
    ) async throws -> [MutationTestState.Change] {
        fileManager.changeCurrentDirectoryPath(state.mutatedProjectDirectoryURL.path)

        let (mutationOutcome, testDuration) = try await benchmarkMutationTesting {
            try await performMutationTesting(using: state)
        }

        let mutationTestOutcome = MutationTestOutcome(
            mutations: mutationOutcome,
            coverage: state.projectCoverage,
            testDuration: testDuration,
            newVersion: state.newVersion
        )

        notificationCenter.post(
            name: .mutationTestingFinished,
            object: mutationTestOutcome
        )

        return [.mutationTestOutcomeGenerated(mutationTestOutcome)]
    }

    private func benchmarkMutationTesting<T>(
        _ work: () async throws -> T
    ) async throws -> (result: T, duration: TimeInterval) {
        let initialTime = now()
        let result = try await work()
        let duration = DateInterval(
            start: initialTime,
            end: now()
        ).duration

        return (result, duration)
    }
}

private extension PerformMutationTesting {
    func performMutationTesting(
        using state: AnyMutationTestState
    ) async throws -> [MutationTestOutcome.Mutation] {
        notificationCenter.post(name: .mutationTestingStarted, object: nil)

        let initialTime = Date()
        let (testSuiteOutcome, testLog) = await ioDelegate.benchmarkTests(
            using: state.muterConfiguration,
            savingResultsIntoFileNamed: "baseline run"
        )

        let timeAfterRunningTestSuite = Date()
        let timePerBuildTestCycle = DateInterval(
            start: initialTime,
            end: timeAfterRunningTestSuite
        ).duration

        guard testSuiteOutcome == .passed else {
            throw MuterError.mutationTestingAborted(
                reason: .baselineTestFailed(log: testLog)
            )
        }

        let mutationLog = MutationTestLog(
            mutationPoint: .none,
            testLog: testLog,
            timePerBuildTestCycle: timePerBuildTestCycle,
            remainingMutationPointsCount: state.mutationPoints.count
        )

        notificationCenter.post(
            name: .newTestLogAvailable,
            object: mutationLog
        )

        return try await testMutation(using: state)
    }

    func testMutation(using state: AnyMutationTestState) async throws -> [MutationTestOutcome.Mutation] {
        if let runnerName = state.muterConfiguration.inProcessRunner,
           state.muterConfiguration.buildSystem == .xcodebuild {
            return try await testMutationInProcess(using: state, runnerName: runnerName)
        }

        var outcomes: [MutationTestOutcome.Mutation] = []
        outcomes.reserveCapacity(state.mutationPoints.count)
        var buildErrors = 0

        for mutationMap in state.mutationMapping {
            for mutationSchema in mutationMap.mutationSchemata {

                try? await ioDelegate.switchOn(
                    schemata: mutationSchema,
                    for: state.projectXCTestRun,
                    at: state.mutatedProjectDirectoryURL
                )

                let (testSuiteOutcome, testLog) = await ioDelegate.runTestSuite(
                    withSchemata: mutationSchema,
                    using: state.muterConfiguration,
                    savingResultsIntoFileNamed: logFileName(
                        for: mutationMap.fileName,
                        schemata: mutationSchema
                    )
                )

                let mutationPoint = MutationPoint(
                    mutationOperatorId: mutationSchema.mutationOperatorId,
                    filePath: mutationSchema.filePath,
                    position: mutationSchema.position
                )

                let outcome = MutationTestOutcome.Mutation(
                    testSuiteOutcome: testSuiteOutcome,
                    mutationPoint: mutationPoint,
                    mutationSnapshot: mutationSchema.snapshot,
                    originalProjectDirectoryUrl: state.projectDirectoryURL,
                    mutatedProjectDirectoryURL: state.mutatedProjectDirectoryURL
                )

                outcomes.append(outcome)

                let mutationLog = MutationTestLog(
                    mutationPoint: mutationPoint,
                    testLog: testLog,
                    timePerBuildTestCycle: .none,
                    remainingMutationPointsCount: .none
                )

                notificationCenter.post(
                    name: .newMutationTestOutcomeAvailable,
                    object: outcome
                )

                notificationCenter.post(
                    name: .newTestLogAvailable,
                    object: mutationLog
                )

                buildErrors = testSuiteOutcome == .buildError ? (buildErrors + 1) : 0
                if buildErrors >= buildErrorsThreshold {
                    throw MuterError.mutationTestingAborted(reason: .tooManyBuildErrors)
                }
            }
        }

        return outcomes
    }

    func testMutationInProcess(
        using state: AnyMutationTestState,
        runnerName: String
    ) async throws -> [MutationTestOutcome.Mutation] {
        let schemata = state.mutationMapping.flatMap { $0.mutationSchemata }

        // The test run file with no mutant switched on: the runner test switches them on itself.
        try await ioDelegate.switchOn(
            schemata: .null,
            for: state.projectXCTestRun,
            at: state.mutatedProjectDirectoryURL
        )

        let runner = InProcessMutationRunner(
            configuration: state.muterConfiguration,
            runnerName: runnerName,
            testRunFileName: "muter.xctestrun",
            workingDirectory: state.mutatedProjectDirectoryURL
        )
        let result = try await runner.run(mutantIdentifiers: schemata.map(\.id))

        return schemata.map { mutationSchema in
            let mutationPoint = MutationPoint(
                mutationOperatorId: mutationSchema.mutationOperatorId,
                filePath: mutationSchema.filePath,
                position: mutationSchema.position
            )
            let outcome = MutationTestOutcome.Mutation(
                testSuiteOutcome: result.outcomes[mutationSchema.id] ?? .buildError,
                mutationPoint: mutationPoint,
                mutationSnapshot: mutationSchema.snapshot,
                originalProjectDirectoryUrl: state.projectDirectoryURL,
                mutatedProjectDirectoryURL: state.mutatedProjectDirectoryURL
            )

            notificationCenter.post(name: .newMutationTestOutcomeAvailable, object: outcome)
            notificationCenter.post(
                name: .newTestLogAvailable,
                object: MutationTestLog(
                    mutationPoint: mutationPoint,
                    testLog: result.logs[mutationSchema.id] ?? "",
                    timePerBuildTestCycle: .none,
                    remainingMutationPointsCount: .none
                )
            )
            return outcome
        }
    }

    func logFileName(
        for fileName: FileName,
        schemata: MutationSchema
    ) -> String {
        "\(fileName)_\(schemata.mutationOperatorId.rawValue)_\(schemata.position).log"
    }
}
