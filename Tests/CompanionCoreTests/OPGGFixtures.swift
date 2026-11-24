enum OPGGFixtures {
    /// recorded response: the data field order (core, boots, starter, fourth, fifth) differs from the request order.
    static let jinxResponse = #"""
    {"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"class LolGetChampionAnalysis: data\nclass Data: core_items,boots,starter_items,fourth_items,fifth_items\nclass CoreItems: ids\n\nLolGetChampionAnalysis(Data(CoreItems([2523,3085,3031]),CoreItems([3006]),CoreItems([1086,2003,2003]),[CoreItems([3036]),CoreItems([3031]),CoreItems([3033])],[CoreItems([3026]),CoreItems([3072]),CoreItems([3139])]))"}]}}
    """#

    /// recorded `lol_list_aram_augments` shape, shortened: unnamed rows exist, and the order is by pick rate.
    static let augmentsResponse = #"""
    {"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"class LolListAramAugments: data\nclass Data: augments\nclass Augment: id,name,tier,performance,popular\n\nLolListAramAugments(Data([Augment(1080,\"Tank It Or Leave It\",3,74.28,0.22),Augment(1250,null,3,99,0.21),Augment(1335,\"Goldrend\",3,82.79,0.2),Augment(1315,\"Swift and Safe\",3,80.43,0.2),Augment(1389,\"Hand of Baron\",4,84.48,0.09),Augment(1322,\"Get Excited!\",4,76.34,0.18),Augment(1150,\"Bread And Jam\",4,72.24,0.16),Augment(1011,\"Can't Touch This\",5,71.46,0.04)]))"}]}}
    """#
}
