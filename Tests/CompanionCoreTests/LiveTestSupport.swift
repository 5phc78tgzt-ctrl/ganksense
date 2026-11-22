// foundation only, never testing: see coordinatortestsupport.swift.
import Foundation
@testable import CompanionCore

func loadFixtureData(_ name: String) throws -> Data {
    guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
        throw URLError(.fileDoesNotExist)
    }
    return try Data(contentsOf: url)
}

func loadSnapshot(_ name: String) throws -> LiveGameSnapshot {
    try JSONDecoder().decode(LiveGameSnapshot.self, from: loadFixtureData(name))
}

func decodeSnapshot(json: String) throws -> LiveGameSnapshot {
    try JSONDecoder().decode(LiveGameSnapshot.self, from: Data(json.utf8))
}
