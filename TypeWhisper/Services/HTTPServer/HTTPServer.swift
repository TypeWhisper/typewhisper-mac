import Foundation
import Network

final class HTTPServer {
    private let router: APIRouter
    private var listener: NWListener?
    private let serverQueue = DispatchQueue(label: "com.typewhisper.httpserver")

    var onStateChange: ((Bool) -> Void)?

    init(router: APIRouter) {
        self.router = router
    }

    func start(port: UInt16) throws {
        stop()

        let nwPort = NWEndpoint.Port(rawValue: port)!
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: nwPort)

        let newListener = try NWListener(using: params)

        newListener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.onStateChange?(true)
            case .failed, .cancelled:
                self?.onStateChange?(false)
            default:
                break
            }
        }

        newListener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        newListener.start(queue: serverQueue)
        self.listener = newListener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: serverQueue)
        receiveData(on: connection, buffer: Data())
    }

    private func receiveData(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }

            var accumulated = buffer
            if let content {
                accumulated.append(content)
            }

            // Guard against oversized requests before parsing
            if accumulated.count > HTTPRequestParser.maxBodySize + 8192 {
                let response = HTTPResponse.error(status: 413, message: "Payload too large")
                self.send(response, on: connection)
                return
            }

            do {
                let request = try HTTPRequestParser.parse(accumulated)
                let router = self.router
                Task {
                    let response = await router.route(request)
                    self.send(response, on: connection)
                }
            } catch HTTPParseError.incomplete {
                if isComplete || error != nil {
                    let response = HTTPResponse.error(status: 400, message: "Incomplete request")
                    self.send(response, on: connection)
                } else {
                    self.receiveData(on: connection, buffer: accumulated)
                }
            } catch {
                let response = HTTPResponse.error(status: 400, message: "Malformed request")
                self.send(response, on: connection)
            }
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        let data = response.serialized()
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
