class_name AuctionSystem
extends RefCounted

const PlayerData = preload("res://scripts/data/Player.gd")

# 竞拍系统：
# 1. 管理最多 6 轮竞拍
# 2. 每轮公开全部玩家出价
# 3. 根据轮次规则判断是否成交
# 4. 处理流拍与赢家积分结算
#
# 规则解释采用如下实现：
# - 比较“最高价”与“第二高价”的领先幅度
# - 领先幅度比例 = (最高价 - 第二高价) / max(第二高价, 1)
# - 例如第 1 轮要求 >100%，表示最高价必须严格大于第二高价的 2 倍
# - 第 5 轮要求 >0%，表示只要出现唯一最高价即可成交
# - 第 6 轮若仍然最高价平局，则流拍

const MAX_ROUNDS := 6
const ROUND_ADVANTAGE_THRESHOLDS := {
	1: 1.0,
	2: 0.6,
	3: 0.4,
	4: 0.2,
	5: 0.0
}

var current_round: int = 1
var warehouse_total_value: int = 0
var players: Array[PlayerData] = []
var round_history: Array[Dictionary] = []
var auction_finished: bool = false
var auction_result: Dictionary = {}


func start_auction(p_players: Array[PlayerData], p_warehouse_total_value: int) -> void:
	players = p_players
	warehouse_total_value = maxi(0, p_warehouse_total_value)
	current_round = 1
	round_history.clear()
	auction_finished = false
	auction_result = {}

	for player in players:
		player.reset_for_new_auction()


func submit_bid(player_id: int, amount: int) -> void:
	var player = get_player_by_id(player_id)
	if player == null:
		return
	player.set_bid(amount)


func resolve_current_round() -> Dictionary:
	if auction_finished:
		return auction_result

	var revealed_bids = _reveal_bids_for_round()
	var sorted_bids = _build_sorted_bid_records(revealed_bids)
	var round_result = _evaluate_round(sorted_bids)
	round_history.append(round_result)

	if round_result["status"] == "sold":
		_finalize_sale(round_result)
	elif round_result["status"] == "no_sale":
		_finalize_no_sale(round_result)
	else:
		current_round += 1

	return round_result


func get_player_by_id(player_id: int) -> PlayerData:
	for player in players:
		if player.player_id == player_id:
			return player
	return null


func get_current_rule_text() -> String:
	return get_rule_text_for_round(current_round)


func get_rule_text_for_round(round_number: int) -> String:
	match round_number:
		1:
			return "第1轮：最高价领先第二高价 > 100%"
		2:
			return "第2轮：最高价领先第二高价 > 60%"
		3:
			return "第3轮：最高价领先第二高价 > 40%"
		4:
			return "第4轮：最高价领先第二高价 > 20%"
		5:
			return "第5轮：最高价领先第二高价 > 0%"
		6:
			return "第6轮：若最高价仍平局则流拍"
		_:
			return "竞拍已结束"


func get_current_threshold() -> float:
	return get_threshold_for_round(current_round)


func get_threshold_for_round(round_number: int) -> float:
	return float(ROUND_ADVANTAGE_THRESHOLDS.get(round_number, -1.0))


func get_round_history() -> Array[Dictionary]:
	return round_history.duplicate(true)


func is_auction_finished() -> bool:
	return auction_finished


func get_auction_result() -> Dictionary:
	return auction_result.duplicate(true)


func force_no_sale(message: String, revealed_bids: Array[Dictionary] = []) -> Dictionary:
	if auction_finished:
		return auction_result.duplicate(true)

	var sorted_bids = _build_sorted_bid_records(revealed_bids)
	var result = {
		"round": current_round,
		"rule_text": get_rule_text_for_round(current_round),
		"threshold": get_threshold_for_round(current_round),
		"revealed_bids": sorted_bids,
		"highest_bid": int(sorted_bids[0]["bid"]) if not sorted_bids.is_empty() else 0,
		"second_highest_bid": int(sorted_bids[1]["bid"]) if sorted_bids.size() > 1 else 0,
		"advantage_ratio": 0.0,
		"top_bidder_count": 0,
		"top_bidders": [],
		"status": "no_sale",
		"is_finished": true,
		"winner_id": -1,
		"winner_name": "",
		"winning_bid": 0,
		"score_delta": 0,
		"message": message
	}
	round_history.append(result)
	_finalize_no_sale(result)
	return result.duplicate(true)


func get_player_rankings() -> Array[Dictionary]:
	var ranking: Array[Dictionary] = []
	for player in players:
		ranking.append({
			"player_id": player.player_id,
			"display_name": player.display_name,
			"is_human": player.is_human,
			"total_score": player.total_score,
			"last_bid": player.last_revealed_bid
		})

	ranking.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if a["total_score"] == b["total_score"]:
			return a["player_id"] < b["player_id"]
		return a["total_score"] > b["total_score"]
	)

	return ranking


func build_result_summary() -> String:
	if not auction_finished:
		return "竞拍尚未结束。"

	var lines: Array[String] = []
	if auction_result.get("status", "") == "sold":
		lines.append("成交玩家：%s" % auction_result.get("winner_name", ""))
		lines.append("成交价格：%d" % int(auction_result.get("winning_bid", 0)))
		lines.append("仓库真实总价值：%d" % warehouse_total_value)
		lines.append("赢家本局积分变化：%d" % int(auction_result.get("score_delta", 0)))
	else:
		lines.append("本局结果：流拍")
		lines.append("仓库真实总价值：%d" % warehouse_total_value)

	lines.append("最终排名：")
	var ranking = get_player_rankings()
	for index in range(ranking.size()):
		var row: Dictionary = ranking[index]
		lines.append("%d. %s | 总积分: %d" % [
			index + 1,
			row["display_name"],
			row["total_score"]
		])

	return "\n".join(lines)


func _reveal_bids_for_round() -> Array[Dictionary]:
	var revealed_bids: Array[Dictionary] = []
	for player in players:
		var bid_value = player.reveal_bid()
		revealed_bids.append({
			"player_id": player.player_id,
			"display_name": player.display_name,
			"is_human": player.is_human,
			"bid": bid_value
		})
	return revealed_bids


func _build_sorted_bid_records(revealed_bids: Array[Dictionary]) -> Array[Dictionary]:
	var sorted_bids = revealed_bids.duplicate(true)
	sorted_bids.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if a["bid"] == b["bid"]:
			return a["player_id"] < b["player_id"]
		return a["bid"] > b["bid"]
	)
	return sorted_bids


func _evaluate_round(sorted_bids: Array[Dictionary]) -> Dictionary:
	var highest_bid = 0
	var second_highest_bid = 0
	var top_bidders: Array[Dictionary] = []

	if not sorted_bids.is_empty():
		highest_bid = int(sorted_bids[0]["bid"])
		for bid_info in sorted_bids:
			if int(bid_info["bid"]) == highest_bid:
				top_bidders.append(bid_info)
			else:
				break

		if sorted_bids.size() > top_bidders.size():
			second_highest_bid = int(sorted_bids[top_bidders.size()]["bid"])

	var has_unique_highest = top_bidders.size() == 1
	var advantage_ratio = _calculate_advantage_ratio(highest_bid, second_highest_bid)
	var rule_text = get_rule_text_for_round(current_round)
	var threshold = get_threshold_for_round(current_round)

	var result = {
		"round": current_round,
		"rule_text": rule_text,
		"threshold": threshold,
		"revealed_bids": sorted_bids,
		"highest_bid": highest_bid,
		"second_highest_bid": second_highest_bid,
		"advantage_ratio": advantage_ratio,
		"top_bidder_count": top_bidders.size(),
		"top_bidders": top_bidders.duplicate(true),
		"status": "continue",
		"is_finished": false,
		"winner_id": -1,
		"winner_name": "",
		"winning_bid": 0,
		"score_delta": 0,
		"message": ""
	}

	if current_round < 6:
		if has_unique_highest and advantage_ratio > threshold:
			var winner_info: Dictionary = top_bidders[0]
			result["status"] = "sold"
			result["is_finished"] = true
			result["winner_id"] = winner_info["player_id"]
			result["winner_name"] = winner_info["display_name"]
			result["winning_bid"] = winner_info["bid"]
			result["message"] = "第%d轮满足成交条件，%s 以 %d 成交。" % [
				current_round,
				winner_info["display_name"],
				winner_info["bid"]
			]
		else:
			result["message"] = _build_continue_message(has_unique_highest, advantage_ratio, threshold)
	else:
		if has_unique_highest:
			var final_winner: Dictionary = top_bidders[0]
			result["status"] = "sold"
			result["is_finished"] = true
			result["winner_id"] = final_winner["player_id"]
			result["winner_name"] = final_winner["display_name"]
			result["winning_bid"] = final_winner["bid"]
			result["message"] = "第6轮出现唯一最高价，%s 以 %d 成交。" % [
				final_winner["display_name"],
				final_winner["bid"]
			]
		else:
			result["status"] = "no_sale"
			result["is_finished"] = true
			result["message"] = "第6轮最高价仍平局，仓库流拍。"

	return result


func _calculate_advantage_ratio(highest_bid: int, second_highest_bid: int) -> float:
	if highest_bid <= second_highest_bid:
		return 0.0
	if second_highest_bid <= 0:
		return 999999.0
	return float(highest_bid - second_highest_bid) / float(second_highest_bid)


func _build_continue_message(has_unique_highest: bool, advantage_ratio: float, threshold: float) -> String:
	if not has_unique_highest:
		return "第%d轮最高价平局，进入下一轮。" % current_round

	return "第%d轮未达到成交条件，领先幅度 %.2f%%，需要大于 %.2f%%，进入下一轮。" % [
		current_round,
		advantage_ratio * 100.0,
		threshold * 100.0
	]


func _finalize_sale(round_result: Dictionary) -> void:
	auction_finished = true

	var winner = get_player_by_id(int(round_result["winner_id"]))
	if winner != null:
		var score_delta = warehouse_total_value - int(round_result["winning_bid"])
		winner.add_score(score_delta)
		round_result["score_delta"] = score_delta

	auction_result = round_result.duplicate(true)


func _finalize_no_sale(round_result: Dictionary) -> void:
	auction_finished = true
	auction_result = round_result.duplicate(true)
