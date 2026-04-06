class_name NetworkManager
extends Node

signal status_changed(message: String, is_error: bool)
signal room_state_changed(room_state: Dictionary)
signal match_started(payload: Dictionary)
signal round_opened(payload: Dictionary)
signal round_resolved(payload: Dictionary)
signal match_finished(payload: Dictionary)
signal disconnected(reason: String)

const PlayerData = preload("res://scripts/data/Player.gd")
const ItemData = preload("res://scripts/data/Item.gd")
const WarehouseGeneratorScript = preload("res://scripts/core/WarehouseGenerator.gd")
const AuctionSystemScript = preload("res://scripts/core/AuctionSystem.gd")

const MIN_ROOM_PLAYERS := 2
const MAX_ROOM_PLAYERS := 4
const DEFAULT_PORT := 7000
const DEFAULT_ADDRESS := "127.0.0.1"
const ROUND_TIME_LIMIT_SECONDS := 60

var _peer: ENetMultiplayerPeer
var _local_player_name: String = ""
var _server_port: int = DEFAULT_PORT
var _server_address: String = DEFAULT_ADDRESS
var _room_players: Dictionary = {}
var _room_in_match: bool = false
var _submitted_bids: Dictionary = {}
var _server_players: Array[PlayerData] = []
var _server_warehouse_generator: WarehouseGeneratorScript
var _server_auction_system: AuctionSystemScript
var _server_warehouse_items: Array[ItemData] = []
var _server_warehouse_data: Dictionary = {}
var _is_leaving_room: bool = false
var _local_can_submit_bid: bool = false
var _round_timer: Timer
var _round_deadline_msec: int = 0
var _last_round_timeout_eliminations: Array[String] = []
var _rpc_ready_peers: Dictionary = {}
var _pending_join_broadcast_peers: Dictionary = {}


func _ready() -> void:
	_apply_multiplayer_root_path()

	_round_timer = Timer.new()
	_round_timer.name = "RoundTimer"
	_round_timer.one_shot = true
	_round_timer.timeout.connect(_on_server_round_timeout)
	add_child(_round_timer)

	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)


func host_room(player_name: String, port: int = DEFAULT_PORT) -> void:
	leave_room(false)

	_local_player_name = _sanitize_player_name(player_name)
	_server_port = port
	_server_address = _get_preferred_local_address()

	var peer = ENetMultiplayerPeer.new()
	var error = peer.create_server(port, MAX_ROOM_PLAYERS)
	if error != OK:
		_emit_local_status("创建房间失败，端口 %d 无法监听。" % port, true)
		return

	_peer = peer
	multiplayer.multiplayer_peer = peer
	_apply_multiplayer_root_path()

	_room_players.clear()
	_rpc_ready_peers.clear()
	_pending_join_broadcast_peers.clear()
	_room_in_match = false
	_submitted_bids.clear()
	_register_room_player(multiplayer.get_unique_id(), _local_player_name)
	_rpc_ready_peers[multiplayer.get_unique_id()] = true
	_emit_local_status("房间已创建，等待其他玩家加入。局域网加入地址：%s:%d" % [_server_address, _server_port], false)
	_broadcast_room_state()


func join_room(player_name: String, address: String, port: int = DEFAULT_PORT) -> void:
	leave_room(false)

	_local_player_name = _sanitize_player_name(player_name)
	_server_address = address.strip_edges()
	if _server_address.is_empty():
		_server_address = DEFAULT_ADDRESS
	_server_port = port

	var peer = ENetMultiplayerPeer.new()
	var error = peer.create_client(_server_address, port)
	if error != OK:
		_emit_local_status("连接房间失败，请检查地址和端口。", true)
		return

	_peer = peer
	multiplayer.multiplayer_peer = peer
	_apply_multiplayer_root_path()
	_emit_local_status("正在连接到 %s:%d ..." % [_server_address, port], false)


func leave_room(emit_message: bool = true) -> void:
	if multiplayer.multiplayer_peer == null:
		_reset_local_state()
		return

	_is_leaving_room = true
	if _peer != null:
		_peer.close()
	multiplayer.multiplayer_peer = null
	_reset_local_state()

	if emit_message:
		_emit_local_status("已离开房间。", false)
		disconnected.emit("已离开房间。")

	_is_leaving_room = false


func set_ready(is_ready: bool) -> void:
	if multiplayer.multiplayer_peer == null or _room_in_match:
		return

	if multiplayer.is_server():
		_server_apply_ready(multiplayer.get_unique_id(), is_ready)
	else:
		_server_set_ready.rpc_id(1, is_ready)


func submit_bid(amount: int) -> bool:
	if multiplayer.multiplayer_peer == null or not _room_in_match:
		return false
	if not _local_can_submit_bid:
		return false

	var final_amount = maxi(0, amount)
	if multiplayer.is_server():
		var accepted = _server_apply_bid(multiplayer.get_unique_id(), final_amount)
		if accepted:
			_local_can_submit_bid = false
		return accepted
	else:
		_server_submit_bid.rpc_id(1, final_amount)
		_local_can_submit_bid = false
		return true


func can_submit_bid() -> bool:
	return _local_can_submit_bid and _room_in_match


func get_round_seconds_left() -> int:
	if not _room_in_match:
		return 0
	if multiplayer.is_server():
		return _get_server_round_seconds_left()
	if _round_deadline_msec <= 0:
		return 0
	return maxi(0, int(ceil(float(_round_deadline_msec - Time.get_ticks_msec()) / 1000.0)))


func get_local_peer_id() -> int:
	if multiplayer.multiplayer_peer == null:
		return -1
	return multiplayer.get_unique_id()


func is_room_joined() -> bool:
	return multiplayer.multiplayer_peer != null


func is_match_active() -> bool:
	return _room_in_match


@rpc("any_peer", "call_remote", "reliable")
func _server_request_join(player_name: String) -> void:
	if not multiplayer.is_server():
		return

	var remote_peer_id = multiplayer.get_remote_sender_id()
	if _room_in_match:
		_reject_join_for_peer(remote_peer_id, "当前房间正在对局中，请稍后再试。")
		return

	if _room_players.size() >= MAX_ROOM_PLAYERS:
		_reject_join_for_peer(remote_peer_id, "房间已满。")
		return

	_register_room_player(remote_peer_id, _sanitize_player_name(player_name))
	_pending_join_broadcast_peers[remote_peer_id] = true
	if bool(_rpc_ready_peers.get(remote_peer_id, false)):
		_finalize_join_for_peer(remote_peer_id)


@rpc("any_peer", "call_remote", "reliable")
func _server_mark_rpc_ready() -> void:
	if not multiplayer.is_server():
		return

	var remote_peer_id = multiplayer.get_remote_sender_id()
	_rpc_ready_peers[remote_peer_id] = true
	if bool(_pending_join_broadcast_peers.get(remote_peer_id, false)):
		_finalize_join_for_peer(remote_peer_id)


@rpc("any_peer", "call_remote", "reliable")
func _server_set_ready(is_ready: bool) -> void:
	if not multiplayer.is_server():
		return

	var remote_peer_id = multiplayer.get_remote_sender_id()
	_server_apply_ready(remote_peer_id, is_ready)


@rpc("any_peer", "call_remote", "reliable")
func _server_submit_bid(amount: int) -> void:
	if not multiplayer.is_server():
		return

	var remote_peer_id = multiplayer.get_remote_sender_id()
	_server_apply_bid(remote_peer_id, amount)


@rpc("authority", "call_remote", "reliable")
func _client_receive_room_state(room_state: Dictionary) -> void:
	_room_in_match = bool(room_state.get("match_active", false))
	_round_deadline_msec = int(room_state.get("round_deadline_msec", 0))
	_local_can_submit_bid = _can_local_player_submit_from_snapshot(room_state.get("players", []))
	if not _room_in_match:
		_local_can_submit_bid = false
		_round_deadline_msec = 0
	_emit_local_room_state(room_state)


@rpc("authority", "call_remote", "reliable")
func _client_receive_status(message: String, is_error: bool = false) -> void:
	_emit_local_status(message, is_error)


@rpc("authority", "call_remote", "reliable")
func _client_match_started(payload: Dictionary) -> void:
	_room_in_match = true
	_round_deadline_msec = int(payload.get("round_deadline_msec", 0))
	_local_can_submit_bid = _can_local_player_submit_from_snapshot(payload.get("players", []))
	match_started.emit(payload)


@rpc("authority", "call_remote", "reliable")
func _client_round_opened(payload: Dictionary) -> void:
	_room_in_match = true
	_round_deadline_msec = int(payload.get("round_deadline_msec", 0))
	_local_can_submit_bid = _can_local_player_submit_from_snapshot(payload.get("players", []))
	round_opened.emit(payload)


@rpc("authority", "call_remote", "reliable")
func _client_round_resolved(payload: Dictionary) -> void:
	_local_can_submit_bid = false
	_round_deadline_msec = 0
	round_resolved.emit(payload)


@rpc("authority", "call_remote", "reliable")
func _client_match_finished(payload: Dictionary) -> void:
	_room_in_match = false
	_local_can_submit_bid = false
	_round_deadline_msec = 0
	match_finished.emit(payload)


func _server_apply_ready(peer_id: int, is_ready: bool) -> void:
	if _room_in_match or not _room_players.has(peer_id):
		return

	var player_entry = _room_players.get(peer_id, {})
	player_entry["ready"] = is_ready
	_room_players[peer_id] = player_entry
	_broadcast_room_state()

	if _can_start_match():
		_server_start_match()


func _server_apply_bid(peer_id: int, amount: int) -> bool:
	if not _room_in_match or not _room_players.has(peer_id):
		return false
	if _submitted_bids.has(peer_id):
		return false
	if not _is_player_eligible_to_bid(peer_id):
		return false

	_submitted_bids[peer_id] = amount
	_server_auction_system.submit_bid(peer_id, amount)

	if _submitted_bids.size() >= _get_active_bidder_count():
		_server_resolve_round()

	return true


func _server_start_match() -> void:
	_room_in_match = true
	_local_can_submit_bid = true
	_submitted_bids.clear()
	_server_warehouse_generator = WarehouseGeneratorScript.new()
	_server_warehouse_data = _server_warehouse_generator.generate_warehouse()
	_server_warehouse_items.clear()
	for item_value in _server_warehouse_data.get("items", []):
		_server_warehouse_items.append(item_value as ItemData)

	_server_players = _build_server_players_from_room()
	_server_auction_system = AuctionSystemScript.new()
	_server_auction_system.start_auction(
		_server_players,
		int(_server_warehouse_data.get("total_value", 0))
	)
	_prepare_server_round_state()

	for peer_id in _room_players.keys():
		var room_entry = _room_players.get(peer_id, {})
		room_entry["ready"] = false
		room_entry["current_bid"] = 0
		room_entry["last_revealed_bid"] = 0
		room_entry["is_eliminated"] = false
		room_entry["elimination_reason"] = ""
		_room_players[peer_id] = room_entry

	var payload = {
		"grid_size": _serialize_vector2i(_server_warehouse_data.get("grid_size", Vector2i(20, 20))),
		"public_items": _serialize_public_items(_server_warehouse_data.get("public_items", [])),
		"public_summary": _server_warehouse_generator.build_public_summary(_server_warehouse_items),
		"round": _server_auction_system.current_round,
		"rule_text": _server_auction_system.get_current_rule_text(),
		"players": _build_player_snapshots(_server_players),
		"message": "%d 名玩家已就位，服务器已生成新的隐藏仓库。每轮限时 %d 秒。" % [_room_players.size(), ROUND_TIME_LIMIT_SECONDS],
		"round_seconds_left": ROUND_TIME_LIMIT_SECONDS,
		"round_deadline_msec": _round_deadline_msec
	}

	_broadcast_room_state()
	_broadcast_match_started(payload)


func _server_resolve_round() -> void:
	if _server_auction_system == null:
		return

	_local_can_submit_bid = false
	_round_deadline_msec = 0
	_round_timer.stop()

	var round_result = _server_auction_system.resolve_current_round()
	_sync_room_players_from_server_players()
	_apply_timeout_elimination_message(round_result)

	var round_payload = {
		"round_result": round_result,
		"players": _build_player_snapshots(_server_players),
		"round_seconds_left": 0
	}
	_broadcast_round_resolved(round_payload)
	_broadcast_room_state()

	if _server_auction_system.is_auction_finished():
		_room_in_match = false
		_round_deadline_msec = 0
		_round_timer.stop()
		_submitted_bids.clear()

		var final_payload = {
			"status": str(round_result.get("status", "")),
			"message": str(round_result.get("message", "")),
			"items": _serialize_items(_server_warehouse_items),
			"grid_size": _serialize_vector2i(_server_warehouse_data.get("grid_size", Vector2i(20, 20))),
			"players": _build_player_snapshots(_server_players),
			"ranking": _server_auction_system.get_player_rankings(),
			"auction_summary": _server_auction_system.build_result_summary()
		}
		_broadcast_match_finished(final_payload)
		_broadcast_room_state()
		return

	_submitted_bids.clear()
	_prepare_server_round_state()
	if _get_active_bidder_count() <= 0:
		_server_force_no_sale("所有玩家都因超时未出价而结束本局，仓库流拍。")
		return
	var next_round_payload = {
		"round": _server_auction_system.current_round,
		"rule_text": _server_auction_system.get_current_rule_text(),
		"players": _build_player_snapshots(_server_players),
		"message": "第 %d 轮开始，等待所有玩家提交新出价。" % _server_auction_system.current_round,
		"grid_size": _serialize_vector2i(_server_warehouse_data.get("grid_size", Vector2i(20, 20))),
		"public_items": _serialize_public_items(_server_warehouse_data.get("public_items", [])),
		"round_seconds_left": ROUND_TIME_LIMIT_SECONDS,
		"round_deadline_msec": _round_deadline_msec
	}
	_broadcast_round_opened(next_round_payload)


func _server_abort_match(reason: String) -> void:
	_room_in_match = false
	_local_can_submit_bid = false
	_round_deadline_msec = 0
	_round_timer.stop()
	_submitted_bids.clear()
	_server_players.clear()
	_server_warehouse_items.clear()
	_server_warehouse_data.clear()

	for peer_id in _room_players.keys():
		var room_entry = _room_players.get(peer_id, {})
		room_entry["ready"] = false
		room_entry["current_bid"] = 0
		room_entry["last_revealed_bid"] = 0
		room_entry["is_eliminated"] = false
		room_entry["elimination_reason"] = ""
		_room_players[peer_id] = room_entry

	var payload = {
		"status": "aborted",
		"message": reason,
		"items": [],
		"grid_size": Vector2i(20, 20),
		"players": _build_room_player_snapshots(),
		"ranking": [],
		"auction_summary": reason
	}
	_broadcast_match_finished(payload)
	_broadcast_room_state()


func _build_server_players_from_room() -> Array[PlayerData]:
	var result: Array[PlayerData] = []
	for peer_id in _get_sorted_peer_ids():
		var room_entry = _room_players.get(peer_id, {})
		var player = PlayerData.new(int(peer_id), str(room_entry.get("display_name", "")), true)
		player.total_score = int(room_entry.get("total_score", 0))
		player.is_ready = false
		player.network_connected = true
		result.append(player)
	return result


func _sync_room_players_from_server_players() -> void:
	for player in _server_players:
		if not _room_players.has(player.player_id):
			continue
		var room_entry = _room_players.get(player.player_id, {})
		room_entry["total_score"] = player.total_score
		room_entry["last_revealed_bid"] = player.last_revealed_bid
		room_entry["current_bid"] = player.current_bid
		room_entry["is_eliminated"] = player.is_eliminated
		room_entry["elimination_reason"] = player.elimination_reason
		_room_players[player.player_id] = room_entry


func _build_player_snapshots(players: Array[PlayerData]) -> Array[Dictionary]:
	var snapshots: Array[Dictionary] = []
	for player in players:
		snapshots.append(player.to_dict())
	return snapshots


func _build_room_player_snapshots() -> Array[Dictionary]:
	var snapshots: Array[Dictionary] = []
	for peer_id in _get_sorted_peer_ids():
		var room_entry = _room_players.get(peer_id, {})
		snapshots.append({
			"player_id": int(peer_id),
			"display_name": str(room_entry.get("display_name", "")),
			"is_human": true,
			"total_score": int(room_entry.get("total_score", 0)),
			"current_bid": int(room_entry.get("current_bid", 0)),
			"last_revealed_bid": int(room_entry.get("last_revealed_bid", 0)),
			"bid_history": [],
			"score_history": [],
			"is_ready": bool(room_entry.get("ready", false)),
			"is_connected": true,
			"is_eliminated": bool(room_entry.get("is_eliminated", false)),
			"elimination_reason": str(room_entry.get("elimination_reason", ""))
		})
	return snapshots


func _serialize_items(items: Array[ItemData]) -> Array[Dictionary]:
	var serialized: Array[Dictionary] = []
	for item in items:
		var item_data = item.to_full_dict()
		item_data["cells"] = _serialize_cells(item.cells)
		serialized.append(item_data)
	return serialized


func _serialize_public_items(public_items: Array) -> Array[Dictionary]:
	var serialized: Array[Dictionary] = []
	for item_data in public_items:
		var item_dict = item_data as Dictionary
		serialized.append({
			"id": int(item_dict.get("id", 0)),
			"cells": _serialize_cells(item_dict.get("cells", [])),
			"cell_count": int(item_dict.get("cell_count", 0))
		})
	return serialized


func _serialize_cells(cells: Array) -> Array[Dictionary]:
	var serialized: Array[Dictionary] = []
	for cell_value in cells:
		var cell = cell_value as Vector2i
		serialized.append(_serialize_vector2i(cell))
	return serialized


func _serialize_vector2i(value: Variant) -> Dictionary:
	var vector = value as Vector2i
	return {
		"x": vector.x,
		"y": vector.y
	}


func _build_room_state() -> Dictionary:
	var public_items = []
	var grid_size = _serialize_vector2i(Vector2i(20, 20))
	var round_number = 0
	var rule_text = "等待房间开始"

	if _room_in_match:
		public_items = _serialize_public_items(_server_warehouse_data.get("public_items", []))
		grid_size = _serialize_vector2i(_server_warehouse_data.get("grid_size", Vector2i(20, 20)))
		if _server_auction_system != null:
			round_number = _server_auction_system.current_round
			rule_text = _server_auction_system.get_current_rule_text()

	return {
		"players": _build_room_player_snapshots(),
		"connected_count": _room_players.size(),
		"max_players": MAX_ROOM_PLAYERS,
		"match_active": _room_in_match,
		"round_seconds_left": _get_server_round_seconds_left(),
		"round_deadline_msec": _round_deadline_msec,
		"public_items": public_items,
		"grid_size": grid_size,
		"round": round_number,
		"rule_text": rule_text,
		"server_port": _server_port,
		"server_address": _server_address
	}


func _emit_local_room_state(room_state: Dictionary) -> void:
	_room_in_match = bool(room_state.get("match_active", false))
	_round_deadline_msec = int(room_state.get("round_deadline_msec", 0))
	_local_can_submit_bid = _can_local_player_submit_from_snapshot(room_state.get("players", []))
	if not _room_in_match:
		_local_can_submit_bid = false
		_round_deadline_msec = 0

	var local_room_state = room_state.duplicate(true)
	local_room_state["local_peer_id"] = get_local_peer_id()
	local_room_state["is_host"] = multiplayer.is_server()
	room_state_changed.emit(local_room_state)


func _broadcast_room_state() -> void:
	var room_state = _build_room_state()
	for peer_id in _get_sorted_peer_ids():
		if int(peer_id) == multiplayer.get_unique_id():
			_emit_local_room_state(room_state)
		else:
			_client_receive_room_state.rpc_id(int(peer_id), room_state)


func _broadcast_status(message_template: String, format_args: Array = [], is_error: bool = false) -> void:
	var message = message_template % format_args if not format_args.is_empty() else message_template
	for peer_id in _get_sorted_peer_ids():
		if int(peer_id) == multiplayer.get_unique_id():
			_emit_local_status(message, is_error)
		else:
			_client_receive_status.rpc_id(int(peer_id), message, is_error)


func _broadcast_match_started(payload: Dictionary) -> void:
	for peer_id in _get_sorted_peer_ids():
		if int(peer_id) == multiplayer.get_unique_id():
			_room_in_match = true
			_round_deadline_msec = int(payload.get("round_deadline_msec", 0))
			_local_can_submit_bid = _can_local_player_submit_from_snapshot(payload.get("players", []))
			match_started.emit(payload)
		else:
			_client_match_started.rpc_id(int(peer_id), payload)


func _broadcast_round_opened(payload: Dictionary) -> void:
	for peer_id in _get_sorted_peer_ids():
		if int(peer_id) == multiplayer.get_unique_id():
			_room_in_match = true
			_round_deadline_msec = int(payload.get("round_deadline_msec", 0))
			_local_can_submit_bid = _can_local_player_submit_from_snapshot(payload.get("players", []))
			round_opened.emit(payload)
		else:
			_client_round_opened.rpc_id(int(peer_id), payload)


func _broadcast_round_resolved(payload: Dictionary) -> void:
	for peer_id in _get_sorted_peer_ids():
		if int(peer_id) == multiplayer.get_unique_id():
			_local_can_submit_bid = false
			_round_deadline_msec = 0
			round_resolved.emit(payload)
		else:
			_client_round_resolved.rpc_id(int(peer_id), payload)


func _broadcast_match_finished(payload: Dictionary) -> void:
	for peer_id in _get_sorted_peer_ids():
		if int(peer_id) == multiplayer.get_unique_id():
			_room_in_match = false
			_local_can_submit_bid = false
			_round_deadline_msec = 0
			match_finished.emit(payload)
		else:
			_client_match_finished.rpc_id(int(peer_id), payload)


func _register_room_player(peer_id: int, player_name: String) -> void:
	var existing_entry = _room_players.get(peer_id, {})
	var total_score = int(existing_entry.get("total_score", 0))
	_room_players[peer_id] = {
		"display_name": player_name,
		"ready": false,
		"total_score": total_score,
		"current_bid": 0,
		"last_revealed_bid": 0
	}


func _can_start_match() -> bool:
	if _room_in_match:
		return false
	if _room_players.size() < MIN_ROOM_PLAYERS or _room_players.size() > MAX_ROOM_PLAYERS:
		return false

	for room_entry in _room_players.values():
		if not bool(room_entry.get("ready", false)):
			return false
	return true


func _get_sorted_peer_ids() -> Array[int]:
	var peer_ids: Array[int] = []
	for peer_id in _room_players.keys():
		peer_ids.append(int(peer_id))
	peer_ids.sort()
	return peer_ids


func _sanitize_player_name(player_name: String) -> String:
	var trimmed = player_name.strip_edges()
	if trimmed.is_empty():
		return "Player"
	return trimmed.left(18)


func _get_preferred_local_address() -> String:
	var local_addresses = IP.get_local_addresses()
	for address in local_addresses:
		var address_text = str(address)
		if address_text.begins_with("127.") or address_text == "::1":
			continue
		if "." not in address_text:
			continue
		return address_text
	return DEFAULT_ADDRESS


func _disconnect_remote_peer(peer_id: int) -> void:
	if _peer == null:
		return
	_peer.disconnect_peer(peer_id)


func _emit_local_status(message: String, is_error: bool) -> void:
	status_changed.emit(message, is_error)


func _reset_local_state() -> void:
	_peer = null
	_room_players.clear()
	_rpc_ready_peers.clear()
	_pending_join_broadcast_peers.clear()
	_room_in_match = false
	_local_can_submit_bid = false
	_round_deadline_msec = 0
	_round_timer.stop()
	_submitted_bids.clear()
	_server_players.clear()
	_server_warehouse_items.clear()
	_server_warehouse_data.clear()
	_server_auction_system = null
	_server_warehouse_generator = null
	room_state_changed.emit({
		"players": [],
		"connected_count": 0,
		"max_players": MAX_ROOM_PLAYERS,
		"match_active": false,
		"round_seconds_left": 0,
		"round_deadline_msec": 0,
		"public_items": [],
		"grid_size": _serialize_vector2i(Vector2i(20, 20)),
		"round": 0,
		"rule_text": "等待房间开始",
		"local_peer_id": -1,
		"is_host": false,
		"server_port": _server_port,
		"server_address": _server_address
	})


func _on_peer_connected(peer_id: int) -> void:
	if multiplayer.is_server():
		_rpc_ready_peers[peer_id] = false
		_emit_local_status("检测到新连接：Peer %d。" % peer_id, false)


func _on_peer_disconnected(peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	if not _room_players.has(peer_id):
		return

	var display_name = str(_room_players[peer_id].get("display_name", "玩家"))
	_room_players.erase(peer_id)
	_rpc_ready_peers.erase(peer_id)
	_pending_join_broadcast_peers.erase(peer_id)

	if _room_in_match:
		_server_abort_match("%s 已断开连接，本局已取消并返回房间。" % display_name)
	else:
		_broadcast_status("%s 已离开房间。" % display_name)
		_broadcast_room_state()


func _on_connected_to_server() -> void:
	_emit_local_status("已连接服务器，正在加入房间。", false)
	call_deferred("_begin_join_flow")


func _begin_join_flow() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	if multiplayer.multiplayer_peer == null:
		return
	_server_mark_rpc_ready.rpc_id(1)
	await get_tree().process_frame
	await get_tree().process_frame
	_send_join_request()


func _send_join_request() -> void:
	if multiplayer.multiplayer_peer == null:
		return
	_server_request_join.rpc_id(1, _local_player_name)


func _finalize_join_for_peer(peer_id: int) -> void:
	call_deferred("_deferred_finalize_join_for_peer", peer_id)


func _deferred_finalize_join_for_peer(peer_id: int) -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	if multiplayer.multiplayer_peer == null or not multiplayer.is_server():
		return
	if not _room_players.has(peer_id):
		return
	if not bool(_rpc_ready_peers.get(peer_id, false)):
		return
	if not bool(_pending_join_broadcast_peers.get(peer_id, false)):
		return
	_pending_join_broadcast_peers.erase(peer_id)

	_broadcast_status("%s 已加入房间。", [str(_room_players[peer_id].get("display_name", ""))])
	_broadcast_room_state()


func _reject_join_for_peer(peer_id: int, message: String) -> void:
	call_deferred("_deferred_reject_join_for_peer", peer_id, message)


func _deferred_reject_join_for_peer(peer_id: int, message: String) -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	if multiplayer.multiplayer_peer == null or not multiplayer.is_server():
		return
	_client_receive_status.rpc_id(peer_id, message, true)
	_disconnect_remote_peer(peer_id)


func _on_connection_failed() -> void:
	_emit_local_status("连接服务器失败。", true)
	leave_room(false)
	disconnected.emit("连接服务器失败。")


func _on_server_disconnected() -> void:
	if _is_leaving_room:
		return
	_emit_local_status("与服务器的连接已断开。", true)
	leave_room(false)
	disconnected.emit("与服务器的连接已断开。")


func _prepare_server_round_state() -> void:
	_submitted_bids.clear()
	_last_round_timeout_eliminations.clear()

	for player in _server_players:
		player.begin_round()

	_round_deadline_msec = Time.get_ticks_msec() + ROUND_TIME_LIMIT_SECONDS * 1000
	_round_timer.stop()
	_round_timer.wait_time = float(ROUND_TIME_LIMIT_SECONDS)
	_round_timer.start()
	_local_can_submit_bid = _is_player_eligible_to_bid(multiplayer.get_unique_id())


func _on_server_round_timeout() -> void:
	if not multiplayer.is_server() or not _room_in_match:
		return

	var eliminated_names: Array[String] = []
	for player in _server_players:
		if player.is_eliminated:
			continue
		if _submitted_bids.has(player.player_id):
			continue
		player.eliminate("超时未出价")
		eliminated_names.append(player.display_name)
		if _room_players.has(player.player_id):
			var room_entry = _room_players.get(player.player_id, {})
			room_entry["current_bid"] = 0
			_room_players[player.player_id] = room_entry

	_last_round_timeout_eliminations = eliminated_names
	_server_resolve_round()


func _apply_timeout_elimination_message(round_result: Dictionary) -> void:
	if _last_round_timeout_eliminations.is_empty():
		return
	round_result["timed_out_players"] = _last_round_timeout_eliminations.duplicate()
	round_result["message"] = "%s\n超时淘汰：%s。" % [
		str(round_result.get("message", "")),
		", ".join(_last_round_timeout_eliminations)
	]
	_last_round_timeout_eliminations.clear()


func _server_force_no_sale(message: String) -> void:
	var revealed_bids = _server_auction_system._reveal_bids_for_round()
	var final_result = _server_auction_system.force_no_sale(message, revealed_bids)
	_sync_room_players_from_server_players()
	_room_in_match = false
	_local_can_submit_bid = false
	_round_deadline_msec = 0
	_round_timer.stop()
	_submitted_bids.clear()

	var final_payload = {
		"status": str(final_result.get("status", "")),
		"message": str(final_result.get("message", "")),
		"items": _serialize_items(_server_warehouse_items),
		"grid_size": _serialize_vector2i(_server_warehouse_data.get("grid_size", Vector2i(20, 20))),
		"players": _build_player_snapshots(_server_players),
		"ranking": _server_auction_system.get_player_rankings(),
		"auction_summary": _server_auction_system.build_result_summary()
	}
	_broadcast_round_resolved({
		"round_result": final_result,
		"players": _build_player_snapshots(_server_players),
		"round_seconds_left": 0
	})
	_broadcast_match_finished(final_payload)
	_broadcast_room_state()


func _get_active_bidder_count() -> int:
	return _get_active_bidder_ids().size()


func _get_active_bidder_ids() -> Array[int]:
	var active_ids: Array[int] = []
	for player in _server_players:
		if not player.is_eliminated:
			active_ids.append(player.player_id)
	return active_ids


func _is_player_eligible_to_bid(peer_id: int) -> bool:
	for player in _server_players:
		if player.player_id == peer_id:
			return not player.is_eliminated
	return false


func _get_server_round_seconds_left() -> int:
	if not _room_in_match or _round_deadline_msec <= 0:
		return 0
	return maxi(0, int(ceil(float(_round_deadline_msec - Time.get_ticks_msec()) / 1000.0)))


func _can_local_player_submit_from_snapshot(players_payload: Array) -> bool:
	if not _room_in_match:
		return false

	var local_peer_id = get_local_peer_id()
	if local_peer_id < 0:
		return false

	for player_data in players_payload:
		var player_entry = player_data as Dictionary
		if int(player_entry.get("player_id", -1)) != local_peer_id:
			continue
		return not bool(player_entry.get("is_eliminated", false))
	return false


func _apply_multiplayer_root_path() -> void:
	var parent_node = get_parent()
	if parent_node == null:
		return
	multiplayer.root_path = parent_node.get_path()
