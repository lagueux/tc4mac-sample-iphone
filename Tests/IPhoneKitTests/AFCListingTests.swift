import Foundation
import Testing
@testable import IPhoneKit

@Suite("AFC listing parser")
struct AFCListingTests {
    @Test("a file line yields name, size, and date")
    func fileLine() throws {
        let item = try #require(AFCListing.parse(
            "-rw-r--r--    1 mobile mobile    2094466 12 Jul 2021 13:28:13 IMG_0028.HEIC"))
        #expect(item.name == "IMG_0028.HEIC")
        #expect(!item.isFolder)
        #expect(item.size == 2094466)
        #expect(item.created != nil)
    }

    @Test("a directory line is a folder without a size")
    func directoryLine() throws {
        let item = try #require(AFCListing.parse(
            "drwxr-xr-x    2 mobile mobile        384 03 May 2025 13:23:00 100APPLE"))
        #expect(item.isFolder)
        #expect(item.size == nil)
    }

    @Test("names with spaces survive; dot entries and junk are dropped")
    func edgeCases() throws {
        let spaced = try #require(AFCListing.parse(
            "-rw-r--r--    1 mobile mobile       1024 01 Jan 2024 00:00:00 My Great File.pdf"))
        #expect(spaced.name == "My Great File.pdf")
        #expect(AFCListing.parse(
            "drwxr-xr-x    2 mobile mobile        64 01 Jan 2024 00:00:00 .") == nil)
        #expect(AFCListing.parse(
            "drwxr-xr-x    2 mobile mobile        64 01 Jan 2024 00:00:00 ..") == nil)
        #expect(AFCListing.parse("total 123") == nil)
        #expect(AFCListing.parse("") == nil)
    }
}
