enum OPGGFixtures {
    /// recorded response: the data field order (core, boots, starter, fourth, fifth) differs from the request order.
    static let jinxResponse = #"""
    {"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"class LolGetChampionAnalysis: data\nclass Data: core_items,boots,starter_items,fourth_items,fifth_items\nclass CoreItems: ids\n\nLolGetChampionAnalysis(Data(CoreItems([2523,3085,3031]),CoreItems([3006]),CoreItems([1086,2003,2003]),[CoreItems([3036]),CoreItems([3031]),CoreItems([3033])],[CoreItems([3026]),CoreItems([3072]),CoreItems([3139])]))"}]}}
    """#
}
