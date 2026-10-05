import Foundation
import Network
import AppKit
import LightsCore

final class StatusServer {
    private let port: NWEndpoint.Port
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "lights.server", qos: .utility)
    private static let maxRequestBytes = 8192

    /// Every route but /health needs this token: other accounts on an SSH machine can
    /// reach the tunnel, and web pages can reach localhost.
    private let token: String

    init(token: String, port: UInt16 = 9876) {
        self.token = token
        self.port = NWEndpoint.Port(rawValue: port)!
    }

    func start() {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            params.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: .ipv4(.loopback),
                port: port
            )
            let listener = try NWListener(using: params)
            self.listener = listener
            listener.newConnectionHandler = { [weak self] conn in
                self?.handle(conn)
            }
            listener.start(queue: queue)
            NSLog("[Lights] StatusServer listening on 127.0.0.1:\(port.rawValue)")
        } catch {
            NSLog("[Lights] StatusServer failed to start: \(error)")
        }
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        receiveHeaders(conn, buffer: Data())
    }

    /// Reads until the blank line that ends the headers, so a header split across
    /// packets still counts.
    private func receiveHeaders(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: Self.maxRequestBytes) { [weak self] data, _, isComplete, error in
            guard let self else { return conn.cancel() }
            var request = buffer
            if let data { request.append(data) }
            let headersDone = request.range(of: Data("\r\n\r\n".utf8)) != nil
            if !headersDone, !isComplete, error == nil, request.count < Self.maxRequestBytes {
                return self.receiveHeaders(conn, buffer: request)
            }
            guard let text = String(data: request, encoding: .utf8), !text.isEmpty else {
                return conn.cancel()
            }
            self.reply(conn, self.response(for: text))
        }
    }

    private func response(for request: String) -> Response {
        let route = Route(path: parsePath(request))
        if route == .health {
            return Response(status: "200 OK", body: "lights ok")
        }
        if Route.isFromBrowser(request) {
            return Response(status: "403 Forbidden", body: "browsers not allowed")
        }
        guard Route.tokenMatches(Route.token(in: request), token) else {
            return Response(status: "401 Unauthorized", body: "missing or wrong token")
        }
        return respond(to: route)
    }

    private func reply(_ conn: NWConnection, _ response: Response) {
        let body = response.body
        let http = """
        HTTP/1.1 \(response.status)\r
        Content-Type: text/plain; charset=utf-8\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """
        conn.send(content: Data(http.utf8), completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    private func parsePath(_ request: String) -> String {
        let firstLine = request.split(separator: "\r\n", maxSplits: 1).first ?? ""
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return "/" }
        return String(parts[1])
    }

    private struct Response {
        let status: String
        let body: String
    }

    private func respond(to route: Route) -> Response {
        switch route {
        case .signal(let signal, let tab):
            DispatchQueue.main.async {
                LightsModel.shared.receive(signal, tab: tab)
            }
            return Response(status: "200 OK", body: "ok")
        case .status:
            let state = DispatchQueue.main.sync { LightsModel.shared.displayed }
            return Response(status: "200 OK", body: state?.rawValue ?? "off")
        case .snapshot:
            return Response(status: "200 OK", body: snapshotPNG() ?? "error")
        case .health:
            return Response(status: "200 OK", body: "lights ok")
        case .badRequest:
            return Response(status: "400 Bad Request", body: "bad request")
        case .notFound:
            return Response(status: "404 Not Found", body: "unknown route")
        }
    }

    /// Render the floating window's content view to a PNG in the temp folder.
    /// Returns the file path on success. Used for demo / marketing capture
    /// without requiring system Screen Recording permission.
    private func snapshotPNG() -> String? {
        var resultPath: String?
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.main.async {
            defer { group.leave() }
            guard let view = NSApp.windows
                    .first(where: { $0 is FloatingWindow })?.contentView else { return }
            let bounds = view.bounds
            guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
            view.cacheDisplay(in: bounds, to: rep)
            guard let data = rep.representation(using: .png, properties: [:]) else { return }
            // Per-user temp folder, not the shared /tmp.
            let path = NSTemporaryDirectory() + "lights-snapshot-\(Int(Date().timeIntervalSince1970 * 1000)).png"
            do {
                try data.write(to: URL(fileURLWithPath: path))
                resultPath = path
            } catch {
                NSLog("[Lights] snapshot write failed: \(error)")
            }
        }
        _ = group.wait(timeout: .now() + 1.0)
        return resultPath
    }
}
