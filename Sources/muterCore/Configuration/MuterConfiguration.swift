import Foundation
import Yams

struct MuterConfiguration: Equatable, Codable {
    let testCommandArguments: [String]
    let testCommandExecutable: String
    /// File exclusion list.
    let excludeFileList: [String]
    /// Exclusion list of functions for Remove Side Effects.
    let excludeCallList: [String]
    let coverageThreshold: Double
    let testSuiteTimeout: Double?
    /// Name of the runner test that tests every mutant in one launch (see InProcessMutationRunner).
    /// xcodebuild only. Without it, the tests are launched once per mutant.
    let inProcessRunner: String?

    var buildSystem: BuildSystem {
        guard let buildSystem = testCommandExecutable.components(separatedBy: "/").last?.trimmed else {
            return .unknown
        }

        return BuildSystem(rawValue: buildSystem)
    }

    enum CodingKeys: String, CodingKey {
        case testCommandArguments = "arguments"
        case testCommandExecutable = "executable"
        case excludeFileList = "exclude"
        case excludeCallList = "excludeCalls"
        case coverageThreshold
        case testSuiteTimeout = "mutationTestTimeout"
        case inProcessRunner
    }

    init(
        executable: String = "",
        arguments: [String] = [],
        excludeList: [String] = [],
        excludeCallList callList: [String] = [],
        coverageThreshold threshold: Double = 0,
        testSuiteTimeOut timeout: Double? = nil,
        inProcessRunner runner: String? = nil
    ) {
        testCommandExecutable = executable
        testCommandArguments = arguments
        excludeFileList = excludeList
        excludeCallList = callList
        coverageThreshold = threshold
        testSuiteTimeout = timeout
        inProcessRunner = runner
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        testCommandExecutable = try container.decode(String.self, forKey: .testCommandExecutable)
        testCommandArguments = try container.decode([String].self, forKey: .testCommandArguments)

        excludeFileList = container.decode([String].self, default: [], forKey: .excludeFileList)
        excludeCallList = container.decode([String].self, default: [], forKey: .excludeCallList)
        coverageThreshold = container.decode(Double.self, default: 0, forKey: .coverageThreshold)
        testSuiteTimeout = try container.decodeIfPresent(Double.self, forKey: .testSuiteTimeout)
            ?? (try container.decodeIfPresent(Int.self, forKey: .testSuiteTimeout)).flatMap(Double.init)
        inProcessRunner = try container.decodeIfPresent(String.self, forKey: .inProcessRunner)
    }

    init(from data: Data) throws {
        do {
            self = try YAMLDecoder().decode(MuterConfiguration.self, from: data)
        } catch {
            self = try JSONDecoder().decode(MuterConfiguration.self, from: data)
        }
    }
}

extension MuterConfiguration {
    static let fileName = "muter.conf"
    static let `extension` = "yml"
    static let fileNameWithExtension = "\(fileName).\(`extension`)"
    static let legacyFileNameWithExtension = "\(fileName).json"
}

extension MuterConfiguration {
    var asData: Data {
        let encoder = YAMLEncoder()
        return (try! encoder.encode(self)).data(using: .utf8)!
    }
}

extension MuterConfiguration {
    var enableCoverageArguments: [String] {
        let arguments = testCommandArguments

        switch buildSystem {
        case .xcodebuild:
            return arguments + ["-enableCodeCoverage", "YES"]
        case .swift:
            return arguments + ["--enable-code-coverage"]

        case .unknown:
            return arguments
        }
    }

    var buildForTestingArguments: [String] {
        let arguments = testCommandArguments

        switch buildSystem {
        case .xcodebuild:
            return testArgumentsWithtDerivedData() + ["clean", "build-for-testing"]
        case .swift,
             .unknown:
            return arguments
        }
    }

    var derivedDataPath: String {
        guard let index = derivedDataArgumentIndex() else {
            return defaultDerivedData
        }

        return testCommandArguments[index + 1]
    }
    
    private var defaultDerivedData: String { "DerivedData" }

    func testWithoutBuildArguments(with testRunFile: String) -> [String] {
        let arguments = testCommandArguments
        switch buildSystem {
        case .xcodebuild:
            guard let destinationIndex = indexOfArgument("-destination") else {
                return arguments
            }
            // The test selection of the configuration applies to every mutant. Failure diagnostics
            // are never collected: a killed mutant is a failing test run, and collecting them takes
            // minutes per run.
            let testSelectionArguments = testCommandArguments.filter {
                $0.hasPrefix("-only-testing:") || $0.hasPrefix("-skip-testing:")
            }
            return [
                "test-without-building",
                testCommandArguments[destinationIndex],
                testCommandArguments[destinationIndex + 1],
                "-xctestrun",
                testRunFile,
                "-collect-test-diagnostics",
                "never"
            ] + testSelectionArguments
        case .swift:
            return arguments + ["--skip-build"]
        case .unknown:
            return arguments
        }
    }

    /// The suites of each `-only-testing:<Target>/<Suite>` argument, by target.
    var testSelectionByTarget: [String: [String]] {
        testCommandArguments
            .filter { $0.hasPrefix("-only-testing:") }
            .reduce(into: [:]) { selection, argument in
                let parts = argument.dropFirst("-only-testing:".count).split(separator: "/", maxSplits: 1)
                guard parts.count == 2 else {
                    return
                }
                selection[String(parts[0]), default: []].append(String(parts[1]))
            }
    }

    /// The arguments that run only the in-process runner test, which then runs the selected suites itself.
    func inProcessTestArguments(testRunFileName: String, runnerTest: String) -> [String] {
        guard let destinationIndex = indexOfArgument("-destination") else {
            return testCommandArguments
        }
        return [
            "test-without-building",
            testCommandArguments[destinationIndex],
            testCommandArguments[destinationIndex + 1],
            "-xctestrun",
            testRunFileName,
            "-collect-test-diagnostics",
            "never",
            "-only-testing:\(runnerTest)"
        ]
    }

    private func indexOfArgument(_ arg: String) -> Int? {
        testCommandArguments.firstIndex(of: arg)
    }

    private func derivedDataArgumentIndex() -> Int? {
        indexOfArgument("-derivedDataPath")
    }

    private func testArgumentsWithtDerivedData() -> [String] {
        guard derivedDataArgumentIndex() == nil else {
            return testCommandArguments
        }
        
        guard let testArgsIndex = indexOfArgument("test") else {
            return testCommandArguments
        }
        
        var args = testCommandArguments
        args.remove(at: testArgsIndex)
        args.append("-derivedDataPath")
        args.append(defaultDerivedData)
        
        return args
    }
}
