@testable import muterCore
import XCTest

final class InProcessMutationRunnerTests: MuterTestCase {
    // MARK: - Runner log

    func test_logParsesStartedAndFinishedMutants() {
        let log = InProcessRunnerLog("""
        Test Suite 'All tests' started
        MUTER_MUTANT_STARTED File_RemoveSideEffects_1_2_3
        MUTER_MUTANT_FINISHED File_RemoveSideEffects_1_2_3 1
        MUTER_MUTANT_STARTED File_SwapTernary_4_5_6
        MUTER_MUTANT_FINISHED File_SwapTernary_4_5_6 0
        """)

        XCTAssertEqual(log.started, ["File_RemoveSideEffects_1_2_3", "File_SwapTernary_4_5_6"])
        XCTAssertEqual(log.finished.map { $0.identifier }, ["File_RemoveSideEffects_1_2_3", "File_SwapTernary_4_5_6"])
        XCTAssertEqual(log.finished.map { $0.exitCode }, [1, 0])
        XCTAssertTrue(log.hasStarted)
        XCTAssertEqual(log.progressLineCount, 4)
        XCTAssertNil(log.unfinished)
    }

    func test_logReportsTheMutantThatWasRunningWhenTheLaunchEnded() {
        let log = InProcessRunnerLog("""
        MUTER_MUTANT_STARTED A
        MUTER_MUTANT_FINISHED A 0
        MUTER_MUTANT_STARTED B
        Fatal error: Unexpectedly found nil
        """)

        XCTAssertEqual(log.unfinished, "B")
    }

    func test_logWithoutProgressHasNotStarted() {
        let log = InProcessRunnerLog("xcodebuild: error: Failed to build workspace")

        XCTAssertFalse(log.hasStarted)
        XCTAssertNil(log.unfinished)
        XCTAssertEqual(log.progressLineCount, 0)
    }

    func test_logIgnoresMalformedFinishedLines() {
        let log = InProcessRunnerLog("""
        MUTER_MUTANT_STARTED A
        MUTER_MUTANT_FINISHED A
        MUTER_MUTANT_FINISHED A notANumber
        """)

        XCTAssertTrue(log.finished.isEmpty)
        XCTAssertEqual(log.unfinished, "A")
    }

    func test_excerptSpansFromStartedToFinished() {
        let log = InProcessRunnerLog("""
        MUTER_MUTANT_STARTED A
        ✘ Test "a" recorded an issue
        MUTER_MUTANT_FINISHED A 1
        MUTER_MUTANT_STARTED B
        MUTER_MUTANT_FINISHED B 0
        """)

        XCTAssertEqual(log.excerpt(for: "A"), """
        MUTER_MUTANT_STARTED A
        ✘ Test "a" recorded an issue
        MUTER_MUTANT_FINISHED A 1
        """)
        XCTAssertEqual(log.excerpt(for: "C"), "")
    }

    func test_excerptOfAnUnfinishedMutantRunsToTheEndOfTheLog() {
        let log = InProcessRunnerLog("""
        MUTER_MUTANT_STARTED A
        Fatal error
        """)

        XCTAssertEqual(log.excerpt(for: "A"), """
        MUTER_MUTANT_STARTED A
        Fatal error
        """)
    }

    // MARK: - Outcomes across targets

    func test_aMutantKilledInAnyTargetIsKilled() {
        XCTAssertEqual(InProcessMutationRunner.combine(nil, .passed), .passed)
        XCTAssertEqual(InProcessMutationRunner.combine(.passed, .failed), .failed)
        XCTAssertEqual(InProcessMutationRunner.combine(.failed, .passed), .failed)
        XCTAssertEqual(InProcessMutationRunner.combine(.timeout, .runtimeError), .runtimeError)
        XCTAssertEqual(InProcessMutationRunner.combine(.runtimeError, .timeout), .runtimeError)
    }

    func test_aMutantThatTimedOutAndWasNotKilledTimedOut() {
        XCTAssertEqual(InProcessMutationRunner.combine(.passed, .timeout), .timeout)
        XCTAssertEqual(InProcessMutationRunner.combine(.timeout, .passed), .timeout)
        XCTAssertEqual(InProcessMutationRunner.combine(.passed, .passed), .passed)
    }

    // MARK: - Configuration

    func test_inProcessRunnerIsReadFromTheConfiguration() throws {
        let configuration = try MuterConfiguration(from: Data("""
        executable: /usr/bin/xcodebuild
        arguments: [test]
        inProcessRunner: MuterInProcessRunner
        """.utf8))

        XCTAssertEqual(configuration.inProcessRunner, "MuterInProcessRunner")
    }

    func test_inProcessRunnerIsOptional() throws {
        let configuration = try MuterConfiguration(from: Data("""
        executable: /usr/bin/xcodebuild
        arguments: [test]
        """.utf8))

        XCTAssertNil(configuration.inProcessRunner)
    }

    func test_testSelectionGroupsTheSuitesByTarget() {
        let configuration = MuterConfiguration(
            executable: "/usr/bin/xcodebuild",
            arguments: [
                "test",
                "-only-testing:AppTests/FeatureTests",
                "-only-testing:AppTests/OtherTests",
                "-only-testing:SDKTests/ModelTests",
                "-only-testing:WholeTarget",
                "-skip-testing:AppTests/SlowTests",
            ]
        )

        XCTAssertEqual(configuration.testSelectionByTarget, [
            "AppTests": ["FeatureTests", "OtherTests"],
            "SDKTests": ["ModelTests"],
        ])
    }

    func test_inProcessTestArgumentsRunOnlyTheRunnerTest() {
        let configuration = MuterConfiguration(
            executable: "/usr/bin/xcodebuild",
            arguments: [
                "test",
                "-scheme",
                "App",
                "-destination",
                "platform=iOS Simulator,name=iPhone 17",
                "-only-testing:AppTests/FeatureTests",
                "SWIFT_TREAT_WARNINGS_AS_ERRORS=NO",
            ],
            inProcessRunner: "MuterInProcessRunner"
        )

        XCTAssertEqual(
            configuration.inProcessTestArguments(
                testRunFileName: "muter.xctestrun",
                runnerTest: "AppTests/MuterInProcessRunner"
            ),
            [
                "test-without-building",
                "-destination",
                "platform=iOS Simulator,name=iPhone 17",
                "-xctestrun",
                "muter.xctestrun",
                "-collect-test-diagnostics",
                "never",
                "-only-testing:AppTests/MuterInProcessRunner",
            ]
        )
    }
}
