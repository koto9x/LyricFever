//
//  MusicAssistantPlayerTests.swift
//  LyricFeverTests
//

import XCTest
@testable import Lyric_Fever

final class MusicAssistantPlayerTests: XCTestCase {

    /// Real shape captured from MA 2.9.5 `player_queues/all` for a PWA player.
    /// `current_item.name` is a combined "Artist - Title" display string;
    /// `media_item.name` is the clean track title. The parser must prefer the
    /// clean title or lyric lookups query the wrong track name.
    private func queueDict(currentItemName: String? = "Hatchie - Part That Bleeds",
                           includeMediaItem: Bool = true) -> [String: Any] {
        var currentItem: [String: Any] = [
            "queue_item_id": "1c15072ad3314e6fa674c09f06681d2f",
            "duration": 204.0,
            "image": ["path": "https://example.com/art.jpg", "remotely_accessible": true],
        ]
        if let currentItemName {
            currentItem["name"] = currentItemName
        }
        if includeMediaItem {
            currentItem["media_item"] = [
                "name": "Part That Bleeds",
                "duration": 204.0,
                "artists": [["name": "Hatchie"]],
                "album": ["name": "Liquorice"],
            ] as [String: Any]
        }
        return [
            "queue_id": "ma_yd2p0f0o2t",
            "display_name": "asgard16_PWA",
            "state": "playing",
            "elapsed_time": 17.13,
            "elapsed_time_last_updated": 1783266377.66,
            "current_item": currentItem,
        ]
    }

    func test_parse_prefersCleanMediaItemTitle() throws {
        let snap = try XCTUnwrap(MusicAssistantPlayer.parseQueueDict(queueDict()))
        XCTAssertEqual(snap.title, "Part That Bleeds")
        XCTAssertEqual(snap.artist, "Hatchie")
        XCTAssertEqual(snap.album, "Liquorice")
    }

    func test_parse_fallsBackToCurrentItemNameWithoutMediaItem() throws {
        let snap = try XCTUnwrap(MusicAssistantPlayer.parseQueueDict(queueDict(includeMediaItem: false)))
        XCTAssertEqual(snap.title, "Hatchie - Part That Bleeds")
        XCTAssertNil(snap.artist)
    }

    func test_parse_basicFields() throws {
        let snap = try XCTUnwrap(MusicAssistantPlayer.parseQueueDict(queueDict()))
        XCTAssertEqual(snap.queueId, "ma_yd2p0f0o2t")
        XCTAssertEqual(snap.state, "playing")
        XCTAssertEqual(snap.durationMs, 204_000)
        XCTAssertEqual(snap.elapsedMs.map { Int($0) }, 17_130)
        XCTAssertEqual(snap.queueItemId, "1c15072ad3314e6fa674c09f06681d2f")
        XCTAssertEqual(snap.imageURL, "https://example.com/art.jpg")
    }

    /// The projection anchor must be LOCAL receipt time, not the server's
    /// `elapsed_time_last_updated` epoch — clock skew between the MA host and
    /// this Mac would otherwise shift every lyric by the skew amount.
    func test_parse_anchorsElapsedToLocalClock() throws {
        let before = Date().timeIntervalSince1970
        let snap = try XCTUnwrap(MusicAssistantPlayer.parseQueueDict(queueDict()))
        let after = Date().timeIntervalSince1970
        let anchor = try XCTUnwrap(snap.elapsedLastUpdated)
        XCTAssertGreaterThanOrEqual(anchor, before)
        XCTAssertLessThanOrEqual(anchor, after)
    }

    func test_parse_returnsNilWithoutQueueId() {
        XCTAssertNil(MusicAssistantPlayer.parseQueueDict(["state": "playing"]))
    }
}
