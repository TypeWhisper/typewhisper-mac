import Foundation
import Darwin
import os

enum HTTPServerError: LocalizedError {
    case socketCreation(errno: Int32)
    case socketOption(errno: Int32)
    case bind(errno: Int32)
    case listen(errno: Int32)

    var errorDescription: String? {
        switch self {
        case .socketCreation(let code):
            "Could not create API server socket: \(Self.message(for: code))"
        case .socketOption(let code):
            "Could not configure API server socket: \(Self.message(for: code))"
        case .bind(let code):
            "Could not bind API server to 127.0.0.1: \(Self.message(for: code))"
        case .listen(let code):
            "Could not listen for API server connections: \(Self.message(for: code))"
        }
    }

    private static func message(for code: Int32) -> String {
        if let cString = strerror(code) {
            return String(cString: cString)
        }
        return "errno \(code)"
    }
}

final class HTTPServer: @unchecked Sendable {
    private let router: APIRouter
    private let acceptQueue = DispatchQueue(label: "com.typewhisper.httpserver.accept")
    private let connectionQueue = DispatchQueue(label: "com.typewhisper.httpserver.connection", attributes: .concurrent)
    private let stateLock = NSLock()
    private var listenSocket: Int32 = -1

    var onStateChange: ((Bool) -> Void)?

    init(router: APIRouter) {
        self.router = router
    }

    func start(port: UInt16) throws {
        stop()

        let socket = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard socket >= 0 else {
            throw HTTPServerError.socketCreation(errno: errno)
        }

        do {
            try configureListenSocket(socket)
            try bindListenSocket(socket, port: port)
            guard Darwin.listen(socket, SOMAXCONN) == 0 else {
                throw HTTPServerError.listen(errno: errno)
            }
        } catch {
            Darwin.close(socket)
            throw error
        }

        stateLock.withLock {
            listenSocket = socket
        }
        onStateChange?(true)

        acceptQueue.async { [weak self] in
            self?.acceptLoop(socket)
        }
    }

    func stop() {
        let socket = stateLock.withLock {
            let socket = listenSocket
            listenSocket = -1
            return socket
        }

        guard socket >= 0 else { return }
        Darwin.shutdown(socket, SHUT_RDWR)
        Darwin.close(socket)
        onStateChange?(false)
    }

    private func configureListenSocket(_ socket: Int32) throws {
        var reuseAddress: Int32 = 1
        guard Darwin.setsockopt(
            socket,
            SOL_SOCKET,
            SO_REUSEADDR,
            &reuseAddress,
            socklen_t(MemoryLayout.size(ofValue: reuseAddress))
        ) == 0 else {
            throw HTTPServerError.socketOption(errno: errno)
        }
    }

    private func bindListenSocket(_ socket: Int32, port: UInt16) throws {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(socket, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard result == 0 else {
            throw HTTPServerError.bind(errno: errno)
        }
    }

    private func acceptLoop(_ socket: Int32) {
        while isCurrentListenSocket(socket) {
            var address = sockaddr_storage()
            var addressLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let clientSocket = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    Darwin.accept(socket, socketAddress, &addressLength)
                }
            }

            if clientSocket < 0 {
                if errno == EINTR { continue }
                break
            }

            connectionQueue.async { [weak self] in
                self?.handleConnection(clientSocket)
            }
        }

        if clearListenSocketIfCurrent(socket) {
            Darwin.close(socket)
            onStateChange?(false)
        }
    }

    private func isCurrentListenSocket(_ socket: Int32) -> Bool {
        stateLock.withLock { listenSocket == socket }
    }

    private func clearListenSocketIfCurrent(_ socket: Int32) -> Bool {
        stateLock.withLock {
            guard listenSocket == socket else { return false }
            listenSocket = -1
            return true
        }
    }

    private func handleConnection(_ socket: Int32) {
        defer {
            Darwin.shutdown(socket, SHUT_RDWR)
            Darwin.close(socket)
        }

        var noSigPipe: Int32 = 1
        _ = Darwin.setsockopt(
            socket,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout.size(ofValue: noSigPipe))
        )

        var accumulated = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)

        while true {
            let received = buffer.withUnsafeMutableBytes { pointer in
                Darwin.recv(socket, pointer.baseAddress, pointer.count, 0)
            }

            if received > 0 {
                accumulated.append(buffer, count: received)
            } else if received == 0 {
                send(.error(status: 400, message: "Incomplete request"), to: socket)
                return
            } else if errno == EINTR {
                continue
            } else {
                return
            }

            if accumulated.count > HTTPRequestParser.maxBodySize + 8192 {
                send(.error(status: 413, message: "Payload too large"), to: socket)
                return
            }

            do {
                let request = try HTTPRequestParser.parse(accumulated)
                send(resolve(request), to: socket)
                return
            } catch HTTPParseError.incomplete {
                continue
            } catch HTTPParseError.bodyTooLarge {
                send(.error(status: 413, message: "Payload too large. Maximum request body size is 256 MiB."), to: socket)
                return
            } catch {
                send(.error(status: 400, message: "Malformed request"), to: socket)
                return
            }
        }
    }

    private func resolve(_ request: HTTPRequest) -> HTTPResponse {
        let semaphore = DispatchSemaphore(value: 0)
        let responseLock = OSAllocatedUnfairLock<HTTPResponse?>(initialState: nil)
        let router = router

        Task {
            let response = await router.route(request)
            responseLock.withLock { $0 = response }
            semaphore.signal()
        }

        semaphore.wait()
        return responseLock.withLock { $0 } ?? .error(status: 503, message: "No response")
    }

    private func send(_ response: HTTPResponse, to socket: Int32) {
        let data = response.serialized()
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var sent = 0
            while sent < data.count {
                let result = Darwin.send(socket, baseAddress.advanced(by: sent), data.count - sent, 0)
                if result > 0 {
                    sent += result
                } else if errno != EINTR {
                    break
                }
            }
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
