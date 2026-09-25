import Foundation

typealias JSON = [String: Any]

let serverName = "computer-use"
let serverVersion = "0.1.0"

func log(_ message: String) {
    FileHandle.standardError.write(Data("[computer-use] \(message)\n".utf8))
}

struct ToolError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

enum Content {
    case text(String)
    case image(Data, mime: String)

    var json: JSON {
        switch self {
        case .text(let text):
            return ["type": "text", "text": text]
        case .image(let data, let mime):
            return ["type": "image", "data": data.base64EncodedString(), "mimeType": mime]
        }
    }
}

let serverInstructions = """
Controls local macOS apps through the Accessibility API, synthetic input and ScreenCaptureKit.
Workflow: get_app_state(app) -> act using element_index values from that state -> get_app_state again \
(it returns only a diff after the first call; indices are stable across calls). \
Prefer element_index actions; fall back to x/y coordinates measured on the latest screenshot of that app. \
Use find_elements to search big trees, batch to chain several actions in one call. \
Run check_permissions first if anything fails with a permission error.
"""

@MainActor
final class Server {
    static let shared = Server()
    private let tools = Tools()

    func run() async {
        do {
            for try await line in FileHandle.standardInput.bytes.lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                await handle(trimmed)
            }
        } catch {
            log("stdin closed: \(error)")
        }
    }

    private func handle(_ line: String) async {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) else {
            send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
            return
        }
        if let batch = object as? [Any] {
            for case let message as JSON in batch { await handleMessage(message) }
        } else if let message = object as? JSON {
            await handleMessage(message)
        }
    }

    private func handleMessage(_ message: JSON) async {
        // Responses from the client and notifications need no reply.
        guard let method = message["method"] as? String, let id = message["id"] else { return }
        let params = message["params"] as? JSON ?? [:]

        switch method {
        case "initialize":
            let version = params["protocolVersion"] as? String ?? "2025-06-18"
            reply(id, [
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": serverName, "version": serverVersion],
                "instructions": serverInstructions,
            ])
        case "ping":
            reply(id, [:])
        case "tools/list":
            reply(id, ["tools": tools.definitions])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? JSON ?? [:]
            reply(id, await tools.call(name, arguments))
        case "resources/list":
            reply(id, ["resources": []])
        case "prompts/list":
            reply(id, ["prompts": []])
        default:
            send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]])
        }
    }

    private func reply(_ id: Any, _ result: JSON) {
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func send(_ object: JSON) {
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else {
            log("failed to encode response")
            return
        }
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }
}
