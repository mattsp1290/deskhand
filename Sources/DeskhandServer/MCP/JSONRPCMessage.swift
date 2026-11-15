import DeskhandCore
import NIOHTTP1

enum JSONRPCID: Hashable, Sendable {
    case string(String)
    case integer(Int64)

    static let integerRange: ClosedRange<Double> = -9_007_199_254_740_991...9_007_199_254_740_991

    init?(_ value: JSONValue) {
        switch value {
        case .string(let text): self = .string(text)
        case .number(let number) where number.rounded(.towardZero) == number && Self.integerRange.contains(number):
            self = .integer(Int64(number))
        default: return nil
        }
    }

    var jsonValue: JSONValue {
        switch self {
        case .string(let text): .string(text)
        case .integer(let integer): JSONValue(integer)
        }
    }
}

struct ProtocolFault: Error, Hashable, Sendable {
    let status: HTTPResponseStatus
    let error: JSONRPCError
    let id: JSONRPCID?

    init(_ status: HTTPResponseStatus, _ error: JSONRPCError, id: JSONRPCID?) {
        self.status = status
        self.error = error
        self.id = id
    }

    init(
        _ status: HTTPResponseStatus, _ code: JSONRPCErrorCode, detail: String? = nil, header: String? = nil,
        id: JSONRPCID?
    ) {
        var data = JSONObject()
        data["detail"] = detail.map(JSONValue.string)
        data["header"] = header.map(JSONValue.string)
        self.init(status, JSONRPCError(code, data: data.isEmpty ? nil : data), id: id)
    }

    var response: HandlerResponse {
        .json(JSONRPCEnvelope.error(error, id: id), status: status)
    }
}

enum JSONRPCEnvelope {
    static func result(_ result: JSONValue, id: JSONRPCID) throws(NonFiniteNumberError) -> [UInt8] {
        try JSONValue.object(["jsonrpc": "2.0", "id": id.jsonValue, "result": result]).canonicalBytes()
    }

    static func error(_ error: JSONRPCError, id: JSONRPCID?) -> [UInt8] {
        let envelope: JSONValue = ["jsonrpc": "2.0", "id": id?.jsonValue ?? .null, "error": error.jsonValue]
        return try! envelope.canonicalBytes()
    }
}
