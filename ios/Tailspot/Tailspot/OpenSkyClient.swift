//
//  OpenSkyClient.swift
//  Tailspot
//
//  Thin HTTP client for the OpenSky Network REST API.
//  https://openskynetwork.github.io/opensky-api/rest.html
//
//  v1 of Tailspot is non-commercial and free, so we use OpenSky's
//  anonymous tier (no auth, area-limited bbox queries, ~10s minimum
//  poll interval). Phase 1 will move this call behind our own backend
//  proxy that adds caching and supports paid providers — at that point
//  this file becomes one of several adapters behind a shared interface.
//
//  Marked `Sendable` so it can be safely held by the @MainActor
//  ADSBManager and called across an `await`. Conformance is trivial:
//  the only stored properties are immutable URLs and URLSession.shared,
//  both Sendable themselves.
//

import Foundation

final class OpenSkyClient: Sendable {

    private let base = URL(string: "https://opensky-network.org/api")!
    private let session = URLSession.shared

    enum ClientError: Error, LocalizedError {
        case badURL
        case http(status: Int)
        case decoding(Error)

        var errorDescription: String? {
            switch self {
            case .badURL:                  return "Bad URL"
            case .http(let s):             return "HTTP \(s)"
            case .decoding(let inner):     return "Decoding: \(inner.localizedDescription)"
            }
        }
    }

    /// Fetch all aircraft with a known position inside the bbox.
    /// Aircraft missing required fields (lat/lon/...) are dropped.
    func aircraftInBbox(
        lamin: Double, lomin: Double, lamax: Double, lomax: Double
    ) async throws -> [Aircraft] {
        var components = URLComponents(
            url: base.appendingPathComponent("states/all"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "lamin", value: String(lamin)),
            URLQueryItem(name: "lomin", value: String(lomin)),
            URLQueryItem(name: "lamax", value: String(lamax)),
            URLQueryItem(name: "lomax", value: String(lomax)),
        ]
        guard let url = components.url else {
            throw ClientError.badURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8.0

        let (data, response) = try await session.data(for: request)

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw ClientError.http(status: http.statusCode)
        }

        do {
            let envelope = try JSONDecoder().decode(StatesEnvelope.self, from: data)
            // states is null when the bbox is empty.
            // FailableDecodable + compactMap drops malformed rows.
            return envelope.states?.compactMap(\.value) ?? []
        } catch {
            throw ClientError.decoding(error)
        }
    }

    private struct StatesEnvelope: Decodable {
        let time: Int
        let states: [FailableDecodable<Aircraft>]?
    }
}
