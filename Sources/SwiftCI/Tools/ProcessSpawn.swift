import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif


/// Finding the program and starting it with `posix_spawn`.
extension ProcessRunnerImpl {
    /// Finds the program. A `command` with a `/` is a path, relative to `workingDirectory`. Any other `command` is
    /// looked up in the `PATH` of `environment`. Empty and relative `PATH` entries are skipped. If `PATH` is missing,
    /// `/usr/bin:/bin` is used. The first directory whose `command` entry is an executable regular file wins.
    nonisolated static func programPath(for tool: Tool, environment: [String: String]) throws -> String {
        if tool.command.contains("/") {
            let path = URL(fileURLWithPath: tool.command, relativeTo: tool.workingDirectory).standardizedFileURL.path
            guard isExecutableFile(path) else {
                throw BuildError(
                    message: "Failed to execute tool '\(tool.command)': there is no executable file at this path. Check the path and that the file is executable."
                )
            }
            return path
        }

        let searchPath = environment["PATH"] ?? "/usr/bin:/bin"
        for directory in searchPath.split(separator: ":") where directory.hasPrefix("/") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(tool.command).path
            if isExecutableFile(candidate) {
                return candidate
            }
        }
        throw BuildError(
            message: "Failed to execute tool '\(tool.command)': no executable with this name in PATH '\(searchPath)'. Check the name, or pass the full path."
        )
    }

    /// Whether `path` is an executable regular file. Symbolic links are followed, so a link to one counts. Directories,
    /// FIFOs, sockets and devices do not.
    nonisolated static func isExecutableFile(_ path: String) -> Bool {
        var info = stat()
        guard stat(path, &info) == 0 else { return false }
        return (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) && access(path, X_OK) == 0
    }

    /// Throws unless SwiftCI can reap its own children. An ignored SIGCHLD, or `SA_NOCLDWAIT`, makes the kernel reap
    /// children on exit. The PID could then be reused before SwiftCI signals it.
    nonisolated static func checkChildReaping(for tool: Tool) throws {
        var action = sigaction()
        guard sigaction(SIGCHLD, nil, &action) == 0 else {
            throw BuildError(
                message: "Failed to execute tool '\(tool.command)': could not read the SIGCHLD disposition. Details: \(String(cString: strerror(errno)))."
            )
        }
        let ignored = handlerValue(action) == 1
        let autoReaped = (action.sa_flags & SA_NOCLDWAIT) != 0
        guard !ignored && !autoReaped else {
            throw BuildError(
                message: "SwiftCI must own child reaping, so the host process must not ignore SIGCHLD or set SA_NOCLDWAIT. Restore the default SIGCHLD disposition. Tool '\(tool.command)' was not started.",
                code: .internal
            )
        }
    }

    /// The raw value of a signal action's handler: 0 for the default, 1 for ignore.
    nonisolated static func handlerValue(_ action: sigaction) -> UInt {
        #if canImport(Darwin)
        unsafeBitCast(action.__sigaction_u.__sa_handler, to: UInt.self)
        #else
        unsafeBitCast(action.__sigaction_handler.sa_handler, to: UInt.self)
        #endif
    }

    /// The descriptors the run keeps after the child has started. `stopReads` has one descriptor per worker: the
    /// stdout reader, the stderr reader, and the writer if there is input.
    nonisolated struct SpawnedPipes {
        let pid: pid_t
        let stdout: Int32
        let stderr: Int32
        let stdinWrite: Int32?
        let stopReads: [Int32]
        let stopWrite: Int32
    }

    /// Starts the program with `posix_spawn`, connected to new pipes. Every descriptor is configured before the spawn:
    /// parent ends are non-blocking and close-on-exec, and the child ends are close-on-exec, so the child gets only
    /// the copies made by the file actions. Every result is checked. On any failure, every descriptor created here
    /// is closed, and the start-failure error is thrown. After a successful spawn nothing else can fail.
    ///
    /// A pipe is created and then marked close-on-exec in a second call, so a program started from another thread in
    /// between could inherit it. Runs are sequential, so this does not happen.
    nonisolated static func spawn(_ tool: Tool, program: String, environment: [String: String]) throws -> SpawnedPipes {
        var owned: [Int32] = []
        func fail(_ reason: String) -> BuildError {
            for fd in owned {
                close(fd)
            }
            owned = []
            return BuildError(message: "Failed to execute tool '\(tool.command)': \(reason)")
        }
        // Checks a call that returns -1 and sets errno.
        func check(_ result: Int32) throws {
            guard result != -1 else { throw fail(errorText(errno)) }
        }
        // Checks a call that returns an error number, as the posix_spawn file action functions do.
        func require(_ code: Int32) throws {
            guard code == 0 else { throw fail(errorText(code)) }
        }
        func makePipe() throws -> (read: Int32, write: Int32) {
            var fds: [Int32] = [-1, -1]
            try check(pipe(&fds))
            owned += fds
            for fd in fds {
                try check(fcntl(fd, F_SETFD, FD_CLOEXEC))
            }
            return (fds[0], fds[1])
        }
        func nonBlocking(_ fd: Int32) throws {
            let flags = fcntl(fd, F_GETFL)
            try check(flags)
            try check(fcntl(fd, F_SETFL, flags | O_NONBLOCK))
        }

        let stdoutPipe = try makePipe()
        let stderrPipe = try makePipe()
        let stop = try makePipe()
        var stdinPipe: (read: Int32, write: Int32)?
        if tool.input != nil {
            stdinPipe = try makePipe()
        }
        let stdinChild: Int32
        if let stdinPipe {
            stdinChild = stdinPipe.read
            try nonBlocking(stdinPipe.write)
            #if os(macOS)
            // A write to a closed pipe must fail with EPIPE, not send SIGPIPE. macOS can say so per descriptor.
            try check(fcntl(stdinPipe.write, F_SETNOSIGPIPE, 1))
            #endif
        } else {
            stdinChild = open("/dev/null", O_RDONLY | O_CLOEXEC)
            try check(stdinChild)
            owned.append(stdinChild)
        }

        // Each worker gets its own duplicate of the stop pipe's read end, so it can close its copy.
        var stopReads: [Int32] = []
        for _ in 0..<(stdinPipe == nil ? 2 : 3) {
            let fd = fcntl(stop.read, F_DUPFD_CLOEXEC, 0)
            try check(fd)
            owned.append(fd)
            stopReads.append(fd)
        }
        try nonBlocking(stdoutPipe.read)
        try nonBlocking(stderrPipe.read)

        // Darwin declares the object as an opaque pointer, Linux as a struct.
        #if os(macOS)
        var actions: posix_spawn_file_actions_t? = nil
        #else
        var actions = posix_spawn_file_actions_t()
        #endif
        try require(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try require(posix_spawn_file_actions_adddup2(&actions, stdinChild, 0))
        try require(posix_spawn_file_actions_adddup2(&actions, stdoutPipe.write, 1))
        try require(posix_spawn_file_actions_adddup2(&actions, stderrPipe.write, 2))
        if let directory = tool.workingDirectory {
            // macOS 10.15 and later, glibc 2.29 and later.
            try require(posix_spawn_file_actions_addchdir_np(&actions, directory.path))
        }

        // argv[0] is the command as given. The program is the resolved path, so no lookup happens in the child.
        guard let arguments = cStrings([tool.command] + tool.arguments) else {
            throw fail("Details: could not allocate the arguments.")
        }
        defer { freeCStrings(arguments) }
        guard let variables = cStrings(environment.map { "\($0.key)=\($0.value)" }) else {
            throw fail("Details: could not allocate the environment.")
        }
        defer { freeCStrings(variables) }

        var pid: pid_t = 0
        let result = posix_spawn(&pid, program, &actions, nil, arguments, variables)
        guard result == 0 else { throw fail(errorText(result)) }

        // The child has its own copies now. Closing the parent's copies makes end of file reach the parent.
        for fd in [stdoutPipe.write, stderrPipe.write, stdinChild, stop.read] {
            close(fd)
        }
        owned = []

        return SpawnedPipes(
            pid: pid,
            stdout: stdoutPipe.read,
            stderr: stderrPipe.read,
            stdinWrite: stdinPipe?.write,
            stopReads: stopReads,
            stopWrite: stop.write
        )
    }

    /// Copies strings into C strings, with a trailing nil. Returns `nil` if an allocation fails. Nothing is left
    /// allocated then.
    nonisolated static func cStrings(_ strings: [String]) -> [UnsafeMutablePointer<CChar>?]? {
        var pointers: [UnsafeMutablePointer<CChar>?] = []
        for string in strings {
            guard let pointer = strdup(string) else {
                freeCStrings(pointers)
                return nil
            }
            pointers.append(pointer)
        }
        pointers.append(nil)
        return pointers
    }

    nonisolated static func freeCStrings(_ pointers: [UnsafeMutablePointer<CChar>?]) {
        for case let pointer? in pointers {
            free(pointer)
        }
    }

    nonisolated static func errorText(_ code: Int32) -> String {
        "Details: \(String(cString: strerror(code)))."
    }
}
