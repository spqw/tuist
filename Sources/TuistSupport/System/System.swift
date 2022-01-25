import Combine
import CombineExt
import Foundation
import RxSwift
import TSCBasic

extension ProcessResult {
    /// Throws a SystemError if the result is unsuccessful.
    ///
    /// - Throws: A SystemError.
    func throwIfErrored() throws {
        switch exitStatus {
        case let .signalled(code):
            let data = Data(try stderrOutput.get())
            throw TuistSupport.SystemError.signalled(command: command(), code: code, standardError: data)
        case let .terminated(code):
            if code != 0 {
                let data = Data(try stderrOutput.get())
                throw TuistSupport.SystemError.terminated(command: command(), code: code, standardError: data)
            }
        }
    }

    /// It returns the command that the process executed.
    /// If the command is executed through xcrun, then the name of the tool is returned instead.
    /// - Returns: Returns the command that the process executed.
    func command() -> String {
        let command = arguments.first!
        if command == "/usr/bin/xcrun" {
            return arguments[1]
        }
        return command
    }
}

public enum SystemError: FatalError, Equatable {
    case terminated(command: String, code: Int32, standardError: Data)
    case signalled(command: String, code: Int32, standardError: Data)
    case parseSwiftVersion(String)

    public var description: String {
        switch self {
        case let .signalled(command, code, data):
            if data.count > 0, let string = String(data: data, encoding: .utf8) {
                return "The '\(command)' was interrupted with a signal \(code) and message:\n\(string)"
            } else {
                return "The '\(command)' was interrupted with a signal \(code)"
            }
        case let .terminated(command, code, data):
            if data.count > 0, let string = String(data: data, encoding: .utf8) {
                return "The '\(command)' command exited with error code \(code) and message:\n\(string)"
            } else {
                return "The '\(command)' command exited with error code \(code)"
            }
        case let .parseSwiftVersion(output):
            return "Couldn't obtain the Swift version from the output: \(output)."
        }
    }

    public var type: ErrorType {
        switch self {
        case .signalled: return .abort
        case .parseSwiftVersion: return .bug
        case .terminated: return .abort
        }
    }
}

public final class System: Systeming {
    /// Shared system instance.
    public static var shared: Systeming = System()

    /// Regex expression used to get the Swift version from the output of the 'swift --version' command.
    // swiftlint:disable:next force_try
    private static var swiftVersionRegex = try! NSRegularExpression(pattern: "Apple Swift version\\s(.+)\\s\\(.+\\)", options: [])

    /// Convenience shortcut to the environment.
    public var env: [String: String] {
        ProcessInfo.processInfo.environment
    }

    func escaped(arguments: [String]) -> String {
        arguments.map { $0.spm_shellEscaped() }.joined(separator: " ")
    }

    // MARK: - Init

    // MARK: - Systeming

    public func run(_ arguments: [String]) throws {
        _ = try capture(arguments)
    }

    public func capture(_ arguments: [String]) throws -> String {
        try capture(arguments, verbose: false, environment: env)
    }

    public func capture(_ arguments: [String],
                        verbose: Bool,
                        environment: [String: String]) throws -> String
    {
        let process = Process(
            arguments: arguments,
            environment: environment,
            outputRedirection: .collect,
            verbose: verbose,
            startNewProcessGroup: false
        )

        logger.debug("\(escaped(arguments: arguments))")

        try process.launch()
        let result = try process.waitUntilExit()
        let output = try result.utf8Output()

        logger.debug("\(output)")

        try result.throwIfErrored()

        return try result.utf8Output()
    }

    public func runAndPrint(_ arguments: [String]) throws {
        try runAndPrint(arguments, verbose: false, environment: env)
    }

    public func runAndPrint(_ arguments: [String],
                            verbose: Bool,
                            environment: [String: String]) throws
    {
        try runAndPrint(
            arguments,
            verbose: verbose,
            environment: environment,
            redirection: .none
        )
    }

    public func runAndCollectOutput(_ arguments: [String]) async throws -> SystemCollectedOutput {
        var values = publisher(arguments)
            .mapToString()
            .collectOutput().values.makeAsyncIterator()

        return try await values.next()!
    }

    public func async(_ arguments: [String]) throws {
        let process = Process(
            arguments: arguments,
            environment: env,
            outputRedirection: .none,
            verbose: false,
            startNewProcessGroup: true
        )

        logger.debug("\(escaped(arguments: arguments))")

        try process.launch()
    }

    @Atomic
    var cachedSwiftVersion: String?

    public func swiftVersion() throws -> String {
        if let cachedSwiftVersion = cachedSwiftVersion {
            return cachedSwiftVersion
        }
        let output = try capture(["/usr/bin/xcrun", "swift", "--version"])
        let range = NSRange(location: 0, length: output.count)
        guard let match = System.swiftVersionRegex.firstMatch(in: output, options: [], range: range) else {
            throw SystemError.parseSwiftVersion(output)
        }
        cachedSwiftVersion = NSString(string: output).substring(with: match.range(at: 1)).spm_chomp()
        return cachedSwiftVersion!
    }

    public func which(_ name: String) throws -> String {
        try capture(["/usr/bin/env", "which", name]).spm_chomp()
    }

    // MARK: Helpers

    /// Converts an array of arguments into a `Foundation.Process`
    /// - Parameters:
    ///   - arguments: Arguments for the process, first item being the executable URL.
    ///   - environment: Environment
    /// - Returns: A `Foundation.Process`
    static func process(_ arguments: [String],
                        environment: [String: String]) -> Foundation.Process
    {
        let executablePath = arguments.first!
        let process = Foundation.Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = Array(arguments.dropFirst())
        process.environment = environment
        return process
    }

    /// Pipe the output of one Process to another
    /// - Parameters:
    ///   - processOne: First Process
    ///   - processTwo: Second Process
    /// - Returns: The pipe
    @discardableResult
    static func pipe(_ processOne: inout Foundation.Process,
                     _ processTwo: inout Foundation.Process) -> Pipe
    {
        let processPipe = Pipe()

        processOne.standardOutput = processPipe
        processTwo.standardInput = processPipe
        return processPipe
    }

    /// PIpe the output of a process into separate output and error pipes
    /// - Parameter process: The process to pipe
    /// - Returns: Tuple that contains the output and error Pipe.
    static func pipeOutput(_ process: inout Foundation.Process) -> (stdOut: Pipe, stdErr: Pipe) {
        let stdOut = Pipe()
        let stdErr = Pipe()

        // Redirect output of Process Two
        process.standardOutput = stdOut
        process.standardError = stdErr

        return (stdOut, stdErr)
    }

    private func runAndPrint(_ arguments: [String],
                             verbose: Bool,
                             environment: [String: String],
                             redirection: TSCBasic.Process.OutputRedirection) throws
    {
        let process = Process(
            arguments: arguments,
            environment: environment,
            outputRedirection: .stream(stdout: { bytes in
                FileHandle.standardOutput.write(Data(bytes))
                redirection.outputClosures?.stdoutClosure(bytes)
            }, stderr: { bytes in
                FileHandle.standardError.write(Data(bytes))
                redirection.outputClosures?.stderrClosure(bytes)
            }),
            verbose: verbose,
            startNewProcessGroup: false
        )

        logger.debug("\(escaped(arguments: arguments))")

        try process.launch()
        let result = try process.waitUntilExit()
        let output = try result.utf8Output()

        logger.debug("\(output)")

        try result.throwIfErrored()
    }

    private func observable(_ arguments: [String], verbose: Bool,
                            environment: [String: String]) -> Observable<SystemEvent<Data>>
    {
        Observable.create { observer -> Disposable in
            let synchronizationQueue = DispatchQueue(label: "io.tuist.support.system")
            var errorData: [UInt8] = []
            let process = Process(
                arguments: arguments,
                environment: environment,
                outputRedirection: .stream(stdout: { bytes in
                    synchronizationQueue.async {
                        observer.onNext(.standardOutput(Data(bytes)))
                    }
                }, stderr: { bytes in
                    synchronizationQueue.async {
                        errorData.append(contentsOf: bytes)
                        observer.onNext(.standardError(Data(bytes)))
                    }
                }),
                verbose: verbose,
                startNewProcessGroup: false
            )
            do {
                try process.launch()
                var result = try process.waitUntilExit()
                result = ProcessResult(
                    arguments: result.arguments,
                    environment: environment,
                    exitStatus: result.exitStatus,
                    output: result.output,
                    stderrOutput: result.stderrOutput.map { _ in errorData }
                )
                try result.throwIfErrored()
                synchronizationQueue.sync {
                    observer.onCompleted()
                }
            } catch {
                synchronizationQueue.sync {
                    observer.onError(error)
                }
            }
            return Disposables.create {
                if process.launched {
                    process.signal(9) // SIGKILL
                }
            }
        }
        .subscribe(on: ConcurrentDispatchQueueScheduler(queue: DispatchQueue.global()))
    }

    private func observable(_ arguments: [String],
                            environment: [String: String],
                            pipeTo secondArguments: [String]) -> Observable<SystemEvent<Data>>
    {
        Observable.create { observer -> Disposable in
            let synchronizationQueue = DispatchQueue(label: "io.tuist.support.system")
            var errorData: [UInt8] = []
            var processOne = System.process(arguments, environment: environment)
            var processTwo = System.process(secondArguments, environment: environment)

            System.pipe(&processOne, &processTwo)

            let pipes = System.pipeOutput(&processTwo)

            pipes.stdOut.fileHandleForReading.readabilityHandler = { fileHandle in
                synchronizationQueue.async {
                    let data: Data = fileHandle.availableData
                    observer.onNext(.standardOutput(data))
                }
            }

            pipes.stdErr.fileHandleForReading.readabilityHandler = { fileHandle in
                synchronizationQueue.async {
                    let data: Data = fileHandle.availableData
                    errorData.append(contentsOf: data)
                    observer.onNext(.standardError(data))
                }
            }

            do {
                try processOne.run()
                try processTwo.run()
                processOne.waitUntilExit()

                let exitStatus = ProcessResult.ExitStatus.terminated(code: processOne.terminationStatus)
                let result = ProcessResult(
                    arguments: arguments,
                    environment: environment,
                    exitStatus: exitStatus,
                    output: .success([]),
                    stderrOutput: .success(errorData)
                )
                try result.throwIfErrored()
                synchronizationQueue.sync {
                    observer.onCompleted()
                }
            } catch {
                synchronizationQueue.sync {
                    observer.onError(error)
                }
            }
            return Disposables.create {
                pipes.stdOut.fileHandleForReading.readabilityHandler = nil
                pipes.stdErr.fileHandleForReading.readabilityHandler = nil
                if processOne.isRunning {
                    processOne.terminate()
                }
            }
        }
        .subscribe(on: ConcurrentDispatchQueueScheduler(queue: DispatchQueue.global()))
    }

    public func publisher(_ arguments: [String]) -> AnyPublisher<SystemEvent<Data>, Error> {
        publisher(arguments, verbose: false, environment: env)
    }

    public func publisher(_ arguments: [String], verbose: Bool,
                          environment: [String: String]) -> AnyPublisher<SystemEvent<Data>, Error>
    {
        AnyPublisher.create { subscriber -> Cancellable in
            let disposable = self
                .observable(arguments, verbose: verbose, environment: environment)
                .subscribe { event in
                    switch event {
                    case .completed:
                        subscriber.send(completion: .finished)
                    case let .error(error):
                        subscriber.send(completion: .failure(error))
                    case let .next(event):
                        subscriber.send(event)
                    }
                }
            return AnyCancellable {
                disposable.dispose()
            }
        }
    }

    public func publisher(_ arguments: [String],
                          pipeTo secondArguments: [String]) -> AnyPublisher<SystemEvent<Data>, Error>
    {
        AnyPublisher.create { subscriber -> Cancellable in
            let disposable = self.observable(arguments, environment: self.env, pipeTo: secondArguments)
                .subscribe { event in
                    switch event {
                    case .completed:
                        subscriber.send(completion: .finished)
                    case let .error(error):
                        subscriber.send(completion: .failure(error))
                    case let .next(event):
                        subscriber.send(event)
                    }
                }
            return AnyCancellable {
                disposable.dispose()
            }
        }
    }
}
