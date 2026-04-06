class_name GameManager
extends Control

const PlayerData = preload("res://scripts/data/Player.gd")
const ItemData = preload("res://scripts/data/Item.gd")
const UIManagerScript = preload("res://scripts/ui/UIManager.gd")
const NetworkManagerScript = preload("res://scripts/network/NetworkManager.gd")

var ui_manager: UIManagerScript
var network_manager: NetworkManagerScript

var players: Array[PlayerData] = []
var warehouse_items: Array[ItemData] = []
var current_grid_size: Vector2i = Vector2i(20, 20)
var local_bid_submitted: bool = false
var round_countdown_seconds: int = -1
var round_countdown_timer: Timer


func _ready() -> void:
	_initialize_modules()
	_reset_to_idle_state()


func _initialize_modules() -> void:
	network_manager = get_node("NetworkManager") as NetworkManagerScript
	ui_manager = get_node("UIManager") as UIManagerScript

	if network_manager == null or ui_manager == null:
		push_error("NetworkManager 或 UIManager 节点缺失，主流程无法初始化。")
		return

	round_countdown_timer = Timer.new()
	round_countdown_timer.name = "RoundCountdownTimer"
	round_countdown_timer.wait_time = 1.0
	round_countdown_timer.one_shot = false
	round_countdown_timer.timeout.connect(_on_round_countdown_tick)
	add_child(round_countdown_timer)

	ui_manager.bind(self)

	ui_manager.host_requested.connect(_on_host_requested)
	ui_manager.join_requested.connect(_on_join_requested)
	ui_manager.ready_toggled.connect(_on_ready_toggled)
	ui_manager.leave_room_requested.connect(_on_leave_room_requested)
	ui_manager.human_bid_submitted.connect(_on_human_bid_submitted)

	network_manager.status_changed.connect(_on_network_status_changed)
	network_manager.room_state_changed.connect(_on_room_state_changed)
	network_manager.match_started.connect(_on_match_started)
	network_manager.round_opened.connect(_on_round_opened)
	network_manager.round_resolved.connect(_on_round_resolved)
	network_manager.match_finished.connect(_on_match_finished)
	network_manager.disconnected.connect(_on_network_disconnected)


func _reset_to_idle_state() -> void:
	players.clear()
	warehouse_items.clear()
	local_bid_submitted = false
	current_grid_size = Vector2i(20, 20)
	_stop_round_countdown()

	ui_manager.setup_players(players)
	ui_manager.update_room_ui({
		"players": [],
		"connected_count": 0,
		"max_players": 4,
		"match_active": false,
		"local_peer_id": -1,
		"is_host": false
	})
	ui_manager.set_match_active(false)
	ui_manager.update_round_info(0, "等待房间开始")
	ui_manager.update_countdown(-1)
	ui_manager.clear_bid_log()
	ui_manager.clear_warehouse()
	ui_manager.set_result_text("请先创建房间或加入房间。2 到 4 名玩家全部点击“准备”后，服务器会自动开始新对局。")


func _on_host_requested(player_name: String, port: int) -> void:
	network_manager.host_room(player_name, port)


func _on_join_requested(player_name: String, address: String, port: int) -> void:
	network_manager.join_room(player_name, address, port)


func _on_ready_toggled(is_ready: bool) -> void:
	network_manager.set_ready(is_ready)


func _on_leave_room_requested() -> void:
	network_manager.leave_room()
	_reset_to_idle_state()
	ui_manager.set_connection_status("已离开房间。")


func _on_human_bid_submitted(amount: int) -> void:
	if not network_manager.is_match_active() or local_bid_submitted:
		return

	var accepted = network_manager.submit_bid(amount)
	if not accepted:
		ui_manager.append_bid_log("本轮出价暂未被服务器接受，请等到本轮真正开始后再提交。", Color("f87171"))
		ui_manager.set_human_bid_enabled(network_manager.can_submit_bid())
		return

	local_bid_submitted = true
	ui_manager.set_human_bid_enabled(false)
	ui_manager.append_bid_log("你已提交本轮出价：%d" % amount, Color("86efac"))
	ui_manager.set_result_text("已提交出价，等待其他玩家完成本轮出价。")


func _on_network_status_changed(message: String, is_error: bool) -> void:
	var color = Color("f87171") if is_error else Color("cbd5e1")
	ui_manager.set_connection_status(message, color)


func _on_room_state_changed(room_state: Dictionary) -> void:
	players = _players_from_payload(room_state.get("players", []))
	var match_active = bool(room_state.get("match_active", false))
	ui_manager.setup_players(players)
	ui_manager.update_room_ui(room_state)
	ui_manager.update_player_panels(
		players,
		int(room_state.get("local_peer_id", -1)),
		match_active
	)

	if match_active:
		current_grid_size = _parse_vector2i(room_state.get("grid_size", current_grid_size))
		var public_items = _parse_public_items(room_state.get("public_items", []))
		if public_items.size() > 0:
			ui_manager.render_warehouse(public_items, current_grid_size)
		ui_manager.update_round_info(
			int(room_state.get("round", 1)),
			str(room_state.get("rule_text", ""))
		)
		var room_seconds_left = int(room_state.get("round_seconds_left", 0))
		if round_countdown_seconds < 0 and room_seconds_left > 0:
			_start_round_countdown(room_seconds_left)
	elif players.is_empty():
		ui_manager.clear_warehouse()
		ui_manager.update_round_info(0, "等待房间开始")
	else:
		_stop_round_countdown()


func _on_match_started(payload: Dictionary) -> void:
	local_bid_submitted = false
	warehouse_items.clear()
	current_grid_size = _parse_vector2i(payload.get("grid_size", Vector2i(20, 20)))
	players = _players_from_payload(payload.get("players", []))

	ui_manager.setup_players(players)
	ui_manager.update_player_panels(players, network_manager.get_local_peer_id(), true)
	ui_manager.set_match_active(true)
	ui_manager.set_human_bid_enabled(network_manager.can_submit_bid())
	ui_manager.set_human_bid_value(0)
	ui_manager.clear_bid_log()
	ui_manager.render_warehouse(_parse_public_items(payload.get("public_items", [])), current_grid_size)
	ui_manager.update_round_info(int(payload.get("round", 1)), str(payload.get("rule_text", "")))
	_start_round_countdown(int(payload.get("round_seconds_left", 0)))

	var public_summary = payload.get("public_summary", {})
	ui_manager.append_bid_log(str(payload.get("message", "服务器已开始新对局。")), Color("93c5fd"))
	ui_manager.append_bid_log("本局共有 %d 个隐藏物品，占用总格数 %d。" % [
		int(public_summary.get("item_count", 0)),
		int(public_summary.get("total_occupied_cells", 0))
	], Color("cbd5e1"))
	ui_manager.append_bid_log("第 %d 轮开始，等待所有玩家提交出价。" % int(payload.get("round", 1)), Color("f8fafc"))
	ui_manager.set_result_text("服务器权威模式已启动。所有玩家提交后会自动公开本轮出价。")


func _on_round_opened(payload: Dictionary) -> void:
	local_bid_submitted = false
	players = _players_from_payload(payload.get("players", []))
	current_grid_size = _parse_vector2i(payload.get("grid_size", current_grid_size))
	ui_manager.setup_players(players)
	ui_manager.update_player_panels(players, network_manager.get_local_peer_id(), true)
	ui_manager.set_match_active(true)
	ui_manager.set_human_bid_enabled(network_manager.can_submit_bid())
	ui_manager.set_human_bid_value(0)
	ui_manager.render_warehouse(_parse_public_items(payload.get("public_items", [])), current_grid_size)
	ui_manager.update_round_info(int(payload.get("round", 1)), str(payload.get("rule_text", "")))
	_start_round_countdown(int(payload.get("round_seconds_left", 0)))
	ui_manager.append_bid_log(str(payload.get("message", "")), Color("f8fafc"))
	ui_manager.set_result_text("新一轮已开始，请提交新的出价。")


func _on_round_resolved(payload: Dictionary) -> void:
	players = _players_from_payload(payload.get("players", []))
	ui_manager.setup_players(players)
	ui_manager.update_player_panels(players, network_manager.get_local_peer_id(), network_manager.is_match_active())

	var round_result = payload.get("round_result", {})
	var revealed_bids = round_result.get("revealed_bids", [])
	_stop_round_countdown()

	ui_manager.append_bid_log("第 %d 轮公开出价：" % int(round_result.get("round", 0)), Color("fcd34d"))
	for bid_info in revealed_bids:
		ui_manager.append_bid_log("%s: %d" % [
			str(bid_info.get("display_name", "")),
			int(bid_info.get("bid", 0))
		], Color("f8fafc"))

	var result_color = Color("fca5a5") if str(round_result.get("status", "")) == "no_sale" else Color("fde68a")
	ui_manager.append_bid_log(str(round_result.get("message", "")), result_color)
	ui_manager.show_round_result(round_result)
	ui_manager.set_human_bid_enabled(false)
	local_bid_submitted = false


func _on_match_finished(payload: Dictionary) -> void:
	local_bid_submitted = false
	players = _players_from_payload(payload.get("players", []))
	ui_manager.setup_players(players)
	ui_manager.update_player_panels(players, network_manager.get_local_peer_id(), false)
	ui_manager.set_match_active(false)
	ui_manager.set_human_bid_enabled(false)
	_stop_round_countdown()

	var status = str(payload.get("status", ""))
	var message = str(payload.get("message", ""))

	if status == "aborted":
		ui_manager.append_bid_log(message, Color("f87171"))
		ui_manager.set_result_text(message)
		return

	warehouse_items = _items_from_payload(payload.get("items", []))
	current_grid_size = _parse_vector2i(payload.get("grid_size", current_grid_size))
	ui_manager.render_revealed_warehouse(warehouse_items, current_grid_size)
	ui_manager.append_bid_log(message, Color("facc15") if status == "sold" else Color("f87171"))
	ui_manager.append_bid_log("本局结束。回到房间后，全员再次点击“准备”即可开始下一局。", Color("93c5fd"))
	ui_manager.show_final_results(
		warehouse_items,
		payload.get("ranking", []),
		str(payload.get("auction_summary", ""))
	)


func _on_network_disconnected(_reason: String) -> void:
	_reset_to_idle_state()


func _players_from_payload(payload_players: Array) -> Array[PlayerData]:
	var parsed_players: Array[PlayerData] = []
	for player_value in payload_players:
		parsed_players.append(PlayerData.from_dict(player_value as Dictionary))
	return parsed_players


func _items_from_payload(payload_items: Array) -> Array[ItemData]:
	var parsed_items: Array[ItemData] = []
	for item_value in payload_items:
		parsed_items.append(ItemData.from_full_dict(item_value as Dictionary))
	return parsed_items


func _start_round_countdown(seconds: int) -> void:
	round_countdown_seconds = maxi(0, seconds)
	ui_manager.update_countdown(round_countdown_seconds)

	if round_countdown_seconds > 0:
		round_countdown_timer.start()
	else:
		round_countdown_timer.stop()


func _stop_round_countdown() -> void:
	round_countdown_seconds = -1
	if round_countdown_timer != null:
		round_countdown_timer.stop()
	ui_manager.update_countdown(-1)


func _on_round_countdown_tick() -> void:
	if round_countdown_seconds <= 0:
		round_countdown_timer.stop()
		ui_manager.update_countdown(0)
		return

	round_countdown_seconds -= 1
	ui_manager.update_countdown(round_countdown_seconds)

	if round_countdown_seconds <= 0:
		round_countdown_timer.stop()


func _parse_public_items(payload_items: Array) -> Array[Dictionary]:
	var parsed_items: Array[Dictionary] = []
	for item_value in payload_items:
		var item_data = item_value as Dictionary
		var parsed_cells: Array[Vector2i] = []
		for cell_value in item_data.get("cells", []):
			parsed_cells.append(_parse_vector2i(cell_value))
		parsed_items.append({
			"id": int(item_data.get("id", 0)),
			"cells": parsed_cells,
			"cell_count": int(item_data.get("cell_count", parsed_cells.size()))
		})
	return parsed_items


func _parse_vector2i(value: Variant) -> Vector2i:
	if value is Vector2i:
		return value as Vector2i
	var data = value as Dictionary
	return Vector2i(
		int(data.get("x", 0)),
		int(data.get("y", 0))
	)
