//
//  SongObjectMigrationTests.swift
//  LyricFeverTests
//

import XCTest
import CoreData
@testable import Lyric_Fever

final class SongObjectMigrationTests: XCTestCase {
    func test_newFieldsDefaultCorrectly() {
        let container = NSPersistentContainer(name: "Lyrics")
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]

        let exp = expectation(description: "load")
        container.loadPersistentStores { _, error in
            XCTAssertNil(error)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)

        let ctx = container.viewContext
        let song = SongObject(context: ctx)
        song.id = "test-id"
        song.title = "Test Track"
        song.language = ""
        song.downloadDate = Date()

        XCTAssertNil(song.appleMusicID, "appleMusicID should default to nil")
        XCTAssertNil(song.albumID, "albumID should default to nil")
        XCTAssertNil(song.sourceProvider, "sourceProvider should default to nil")
        XCTAssertFalse(song.userPicked, "userPicked should default to false")
    }
}
