class_name Player
extends RefCounted

# 玩家基础数据类。
# AI 玩家会在后续步骤继承该类并扩展出价逻辑。

var player_id: int = -1
var display_name: String = ""
var is_human: bool = false
var is_ready: bool = false
var network_connected: bool = true
var is_eliminated: bool = false
var elimination_reason: String = ""

var total_score: int = 0
var current_bid: int = 0
var last_revealed_bid: int = 0
var bid_history: Array[int] = []
var score_history: Array[int] = []


func _init(p_player_id: int = -1, p_display_name: String = "", p_is_human: bool = false) -> void:
	player_id = p_player_id
	display_name = p_display_name
	is_human = p_is_human


func reset_for_new_auction() -> void:
	current_bid = 0
	last_revealed_bid = 0
	is_eliminated = false
	elimination_reason = ""
	bid_history.clear()


func begin_round() -> void:
	current_bid = 0


func set_bid(amount: int) -> void:
	current_bid = maxi(0, amount)


func reveal_bid() -> int:
	last_revealed_bid = current_bid
	bid_history.append(current_bid)
	return last_revealed_bid


func add_score(score_delta: int) -> void:
	total_score += score_delta
	score_history.append(score_delta)


func get_latest_score_delta() -> int:
	if score_history.is_empty():
		return 0
	return score_history[-1]


func get_average_bid() -> float:
	if bid_history.is_empty():
		return 0.0

	var total_bid_sum = 0
	for value in bid_history:
		total_bid_sum += value
	return float(total_bid_sum) / float(bid_history.size())


func can_submit_bid() -> bool:
	return current_bid >= 0 and not is_eliminated


func eliminate(reason: String) -> void:
	is_eliminated = true
	elimination_reason = reason
	current_bid = 0


func get_status_text() -> String:
	return "%s | 当前出价: %d | 总积分: %d" % [
		display_name,
		last_revealed_bid,
		total_score
	]


func to_dict() -> Dictionary:
	return {
		"player_id": player_id,
		"display_name": display_name,
		"is_human": is_human,
		"is_ready": is_ready,
		"is_connected": network_connected,
		"is_eliminated": is_eliminated,
		"elimination_reason": elimination_reason,
		"total_score": total_score,
		"current_bid": current_bid,
		"last_revealed_bid": last_revealed_bid,
		"bid_history": bid_history.duplicate(),
		"score_history": score_history.duplicate()
	}


func apply_dict(data: Dictionary) -> void:
	player_id = int(data.get("player_id", player_id))
	display_name = str(data.get("display_name", display_name))
	is_human = bool(data.get("is_human", is_human))
	is_ready = bool(data.get("is_ready", is_ready))
	network_connected = bool(data.get("is_connected", network_connected))
	is_eliminated = bool(data.get("is_eliminated", is_eliminated))
	elimination_reason = str(data.get("elimination_reason", elimination_reason))
	total_score = int(data.get("total_score", total_score))
	current_bid = int(data.get("current_bid", current_bid))
	last_revealed_bid = int(data.get("last_revealed_bid", last_revealed_bid))

	bid_history.clear()
	for bid_value in data.get("bid_history", []):
		bid_history.append(int(bid_value))

	score_history.clear()
	for score_value in data.get("score_history", []):
		score_history.append(int(score_value))


static func from_dict(data: Dictionary):
	var player = new(
		int(data.get("player_id", -1)),
		str(data.get("display_name", "")),
		bool(data.get("is_human", true))
	)
	player.apply_dict(data)
	return player
