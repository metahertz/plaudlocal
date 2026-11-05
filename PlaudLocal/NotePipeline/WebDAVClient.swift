import Foundation

enum WebDAVError: Error {
    case badURL
    case httpStatus(Int)
}

struct WebDAVClient {
    var baseURL: URL
    var username: String
    var password: String
    var session: URLSession = .shared

    func ensureCollection(_ path: String) async throws {
        let url = try urlFor(path)
        var request = URLRequest(url: url)
        request.httpMethod = "MKCOL"
        request.setValue(authHeader(), forHTTPHeaderField: "Authorization")
        let (_, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        // 201 created, 405 already exists — both OK
        guard [201, 405, 301, 200].contains(code) else { throw WebDAVError.httpStatus(code) }
    }

    func upload(data: Data, toPath path: String) async throws {
        let url = try urlFor(path)
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(authHeader(), forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await session.upload(for: request, from: data)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw WebDAVError.httpStatus(code) }
    }

    private func urlFor(_ path: String) throws -> URL {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var base = baseURL.absoluteString
        if !base.hasSuffix("/") { base += "/" }
        guard let rooted = URL(string: base),
              let url = URL(string: trimmed, relativeTo: rooted)?.absoluteURL else {
            throw WebDAVError.badURL
        }
        return url
    }

    private func authHeader() -> String {
        let raw = "\(username):\(password)"
        let b64 = Data(raw.utf8).base64EncodedString()
        return "Basic \(b64)"
    }
}
