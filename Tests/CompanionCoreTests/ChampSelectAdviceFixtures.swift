// live op.gg responses (ahri mid, ranked), trimmed.
enum ChampSelectAdviceFixtures {
    static let ahriAnalysis = """
    class LolGetChampionAnalysis: data
    class Data: weak_counters,summoner_spells,runes,skills,skill_masteries
    class WeakCounter: champion_id,champion_name,play,win,my_win_rate,counter_win_rate,win_rate
    class SummonerSpells: ids,ids_names,win,play,pick_rate
    class Runes: id,primary_page_id,primary_page_name,primary_rune_ids,primary_rune_names,secondary_page_id,secondary_page_name,secondary_rune_ids,secondary_rune_names,stat_mod_ids,stat_mod_names,play,win,pick_rate
    class Skills: order,play,win,pick_rate
    class SkillMasteries: ids,play,win,pick_rate

    LolGetChampionAnalysis(Data([WeakCounter(950,"Naafiri",362,167,0.46,0.54,0.54),WeakCounter(1,"Annie",1851,872,0.47,0.53,0.53),WeakCounter(105,"Fizz",1833,869,0.47,0.53,0.53),WeakCounter(7,"Rare",12,9,0.2,0.8,0.8)],SummonerSpells([4,14],[4,14],37748,72967,0.69),Runes(8112,8100,"Domination",[8112,8139,8140,8106],["Electrocute","Taste of Blood","Grisly Mementos","Ultimate Hunter"],8200,"Sorcery",[8210,8226],["Transcendence","Manaflow Band"],[5005,5008,5001],[5005,5008,5001],52224,26320,0.48),Skills(["W","Q","E"],43454,25177,0.6),SkillMasteries(["Q","W","E"],67186,39097,0.93)))
    """

    static let zedMatchup = """
    {"lang":"en_US","position":"mid","my_champion":"Ahri","opponent_champion":"Zed","data":{"opponent_champion_tip":"Do not use Charm [E] until Zed closes in.","lane_advantage_champion":"Zed","recommended_play_style":"even"}}
    """

    static let mirrorMatchup = """
    {"my_champion":"Ahri","opponent_champion":"Ahri","data":{"opponent_champion_tip":null,"lane_advantage_champion":null}}
    """
}
