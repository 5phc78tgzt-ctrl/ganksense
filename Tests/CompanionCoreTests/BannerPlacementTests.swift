import Testing
import CoreGraphics
@testable import CompanionCore

@Test func bannerSitsAboveClientOrSlidesOverItsTop() {
    // big display: room above the client.
    let big = CGRect(x: 0, y: 0, width: 2560, height: 1415)
    let client = CGRect(x: 640, y: 300, width: 1280, height: 720)
    #expect(BannerPlacement.frame(client: client, visible: big, height: 100)
        == CGRect(x: 640, y: 1026, width: 1280, height: 100))
    // 1440x900 laptop: 65 pt above the client, so the banner overlaps its top and stays under the menu bar.
    let laptop = CGRect(x: 0, y: 0, width: 1440, height: 875)
    let small = CGRect(x: 80, y: 90, width: 1280, height: 720)
    let f = BannerPlacement.frame(client: small, visible: laptop, height: 100)
    #expect(f.maxY == laptop.maxY && f.minX == 80 && f.width == 1280)
}

@Test func autoStyleGoesSlimOnlyWhenTheFullBannerDoesNotFit() {
    let laptop = CGRect(x: 0, y: 74, width: 1440, height: 795)
    let client = CGRect(x: 80, y: 90, width: 1280, height: 720)
    #expect(BannerPlacement.layout(style: .auto, client: client, visible: laptop, fullHeight: 159) == .slim)
    let tall = CGRect(x: 0, y: 0, width: 2560, height: 1415)
    #expect(BannerPlacement.layout(style: .auto, client: CGRect(x: 640, y: 300, width: 1280, height: 720), visible: tall,
                                   fullHeight: 159) == .full)
    #expect(BannerPlacement.layout(style: .slim, client: nil, visible: tall, fullHeight: 159) == .slim)
}
