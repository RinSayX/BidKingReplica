class_name UIManager
extends Node


class WarehouseOutlineOverlay:
	extends Control

	var grid_size: Vector2i = Vector2i(1, 1)
	var outline_groups: Array[Dictionary] = []
	var grid_origin: Vector2 = Vector2.ZERO
	var cell_draw_size: Vector2 = Vector2.ONE

	func configure_hidden(p_grid_size: Vector2i, p_items: Array[Dictionary], p_color: Color, p_width: float) -> void:
		grid_size = p_grid_size
		outline_groups.clear()
		for item_data in p_items:
			outline_groups.append({
				"cells": (item_data as Dictionary).get("cells", []),
				"color": p_color,
				"width": p_width
			})
		queue_redraw()

	func configure_revealed(p_grid_size: Vector2i, p_items: Array[ItemData], p_width: float, p_palette: Array) -> void:
		grid_size = p_grid_size
		outline_groups.clear()
		for item in p_items:
			outline_groups.append({
				"cells": item.cells,
				"color": _get_revealed_outline_color(item.id, p_palette),
				"width": p_width
			})
		queue_redraw()

	func clear_overlay() -> void:
		outline_groups.clear()
		queue_redraw()

	func set_grid_metrics(p_origin: Vector2, p_cell_draw_size: Vector2) -> void:
		grid_origin = p_origin
		cell_draw_size = p_cell_draw_size
		queue_redraw()

	func _draw() -> void:
		if grid_size.x <= 0 or grid_size.y <= 0:
			return

		for group in outline_groups:
			_draw_item_outline(
				(group.get("cells", []) as Array),
				group.get("color", Color.WHITE) as Color,
				float(group.get("width", 1.0))
			)

	func _draw_item_outline(cells: Array, color: Color, line_width: float) -> void:
		if cells.is_empty():
			return

		var lookup := {}
		for cell_value in cells:
			var cell = cell_value as Vector2i
			lookup["%d,%d" % [cell.x, cell.y]] = true

		for cell_value in cells:
			var cell = cell_value as Vector2i
			if not lookup.has(_cell_key(cell + Vector2i.UP)):
				_draw_edge(cell, "top", color, line_width)
			if not lookup.has(_cell_key(cell + Vector2i.RIGHT)):
				_draw_edge(cell, "right", color, line_width)
			if not lookup.has(_cell_key(cell + Vector2i.DOWN)):
				_draw_edge(cell, "bottom", color, line_width)
			if not lookup.has(_cell_key(cell + Vector2i.LEFT)):
				_draw_edge(cell, "left", color, line_width)

	func _draw_edge(cell: Vector2i, side: String, color: Color, line_width: float) -> void:
		var x = grid_origin.x + float(cell.x) * cell_draw_size.x
		var y = grid_origin.y + float(cell.y) * cell_draw_size.y
		var width = maxf(1.0, line_width)

		match side:
			"top":
				draw_rect(Rect2(x, y, cell_draw_size.x, width), color)
			"right":
				draw_rect(Rect2(x + cell_draw_size.x - width, y, width, cell_draw_size.y), color)
			"bottom":
				draw_rect(Rect2(x, y + cell_draw_size.y - width, cell_draw_size.x, width), color)
			"left":
				draw_rect(Rect2(x, y, width, cell_draw_size.y), color)

	func _get_revealed_outline_color(item_id: int, p_palette: Array) -> Color:
		if p_palette.is_empty():
			return Color.WHITE
		return p_palette[posmod(item_id - 1, p_palette.size())] as Color

	func _cell_key(cell: Vector2i) -> String:
		return "%d,%d" % [cell.x, cell.y]

const PlayerData = preload("res://scripts/data/Player.gd")
const ItemData = preload("res://scripts/data/Item.gd")

signal host_requested(player_name: String, port: int)
signal join_requested(player_name: String, address: String, port: int)
signal ready_toggled(is_ready: bool)
signal leave_room_requested()
signal human_bid_submitted(amount: int)

const GRID_BACKGROUND_COLOR := Color("151821")
const GRID_EMPTY_COLOR := Color("232836")
const GRID_OCCUPIED_COLOR := Color("64748b")
const GRID_LINE_COLOR := Color("0f172a")
const HIDDEN_OUTLINE_COLOR := Color("94a3b8")
const REVEALED_INNER_LINE_COLOR := Color("0b1220")
const HIDDEN_OUTLINE_WIDTH := 2
const HIDDEN_INNER_WIDTH := 0
const REVEALED_OUTLINE_WIDTH := 2
const REVEALED_INNER_WIDTH := 0
const PLAYER_LOCAL_COLOR := Color("38bdf8")
const PLAYER_REMOTE_COLOR := Color("64748b")
const ITEM_OUTLINE_PALETTE := [
	Color("f97316"),
	Color("22c55e"),
	Color("38bdf8"),
	Color("f43f5e"),
	Color("eab308"),
	Color("a855f7"),
	Color("14b8a6"),
	Color("fb7185"),
	Color("84cc16"),
	Color("60a5fa")
]

var _root: Control
var _round_label: Label
var _rule_label: Label
var _countdown_label: Label
var _value_guide_button: Button
var _connection_status_label: Label
var _player_name_edit: LineEdit
var _host_address_edit: LineEdit
var _port_spin_box: SpinBox
var _host_button: Button
var _join_button: Button
var _ready_button: Button
var _leave_button: Button
var _warehouse_grid: Control
var _bid_input_label: Label
var _bid_log: RichTextLabel
var _bid_spin_box: SpinBox
var _submit_bid_button: Button
var _next_round_button: Button
var _players_list: VBoxContainer
var _result_text: RichTextLabel
var _value_guide_overlay: Control
var _value_guide_backdrop: ColorRect
var _value_guide_text: RichTextLabel
var _value_guide_close_button: Button

var _player_row_map: Dictionary = {}
var _grid_size: Vector2i = Vector2i(20, 20)
var _local_player_id: int = -1
var _match_active: bool = false
var _local_ready: bool = false
var _room_joined: bool = false
var _outline_resync_pending: bool = false


func bind(root: Control) -> void:
	_root = root
	_round_label = _root.get_node("SafeArea/RootVBox/HeaderPanel/HeaderHBox/RoundLabel")
	_rule_label = _root.get_node("SafeArea/RootVBox/HeaderPanel/HeaderHBox/RuleLabel")
	_countdown_label = _root.get_node("SafeArea/RootVBox/HeaderPanel/HeaderHBox/CountdownLabel")
	_value_guide_button = _root.get_node("SafeArea/RootVBox/HeaderPanel/HeaderHBox/ValueGuideButton")
	_connection_status_label = _root.get_node("SafeArea/RootVBox/ConnectionPanel/ConnectionMargin/ConnectionVBox/ConnectionStatusLabel")
	_player_name_edit = _root.get_node("SafeArea/RootVBox/ConnectionPanel/ConnectionMargin/ConnectionVBox/ControlsRow/NameEdit")
	_host_address_edit = _root.get_node("SafeArea/RootVBox/ConnectionPanel/ConnectionMargin/ConnectionVBox/ControlsRow/HostAddressEdit")
	_port_spin_box = _root.get_node("SafeArea/RootVBox/ConnectionPanel/ConnectionMargin/ConnectionVBox/ControlsRow/PortSpinBox")
	_host_button = _root.get_node("SafeArea/RootVBox/ConnectionPanel/ConnectionMargin/ConnectionVBox/ButtonsRow/HostButton")
	_join_button = _root.get_node("SafeArea/RootVBox/ConnectionPanel/ConnectionMargin/ConnectionVBox/ButtonsRow/JoinButton")
	_ready_button = _root.get_node("SafeArea/RootVBox/ConnectionPanel/ConnectionMargin/ConnectionVBox/ButtonsRow/ReadyButton")
	_leave_button = _root.get_node("SafeArea/RootVBox/ConnectionPanel/ConnectionMargin/ConnectionVBox/ButtonsRow/LeaveButton")
	_warehouse_grid = _root.get_node("SafeArea/RootVBox/ContentHBox/WarehouseSection/WarehouseVBox/WarehouseGrid")
	_bid_input_label = _root.get_node("SafeArea/RootVBox/ContentHBox/CenterSection/ActionSection/ActionVBox/BidInputLabel")
	_bid_log = _root.get_node("SafeArea/RootVBox/ContentHBox/CenterSection/AuctionSection/AuctionVBox/BidLog")
	_bid_spin_box = _root.get_node("SafeArea/RootVBox/ContentHBox/CenterSection/ActionSection/ActionVBox/BidSpinBox")
	_submit_bid_button = _root.get_node("SafeArea/RootVBox/ContentHBox/CenterSection/ActionSection/ActionVBox/SubmitBidButton")
	_next_round_button = _root.get_node("SafeArea/RootVBox/ContentHBox/CenterSection/ActionSection/ActionVBox/NextRoundButton")
	_players_list = _root.get_node("SafeArea/RootVBox/ContentHBox/PlayersSection/PlayersVBox/PlayersList")
	_result_text = _root.get_node("SafeArea/RootVBox/FooterSection/FooterVBox/ResultText")
	_value_guide_overlay = _root.get_node("ValueGuideOverlay")
	_value_guide_backdrop = _root.get_node("ValueGuideOverlay/Backdrop")
	_value_guide_text = _root.get_node("ValueGuideOverlay/Center/Panel/Margin/VBox/GuideText")
	_value_guide_close_button = _root.get_node("ValueGuideOverlay/Center/Panel/Margin/VBox/CloseButton")

	_host_button.pressed.connect(_on_host_pressed)
	_join_button.pressed.connect(_on_join_pressed)
	_ready_button.pressed.connect(_on_ready_pressed)
	_leave_button.pressed.connect(_on_leave_pressed)
	_submit_bid_button.pressed.connect(_on_submit_bid_pressed)
	_value_guide_button.pressed.connect(_open_value_guide)
	_value_guide_close_button.pressed.connect(_close_value_guide)
	_value_guide_backdrop.gui_input.connect(_on_value_guide_backdrop_input)

	_next_round_button.disabled = true
	_next_round_button.text = "等待服务器结算"
	_bid_input_label.text = "你的出价"
	_value_guide_button.text = "价值参考"
	_value_guide_close_button.text = "关闭"
	_value_guide_overlay.visible = false
	_value_guide_text.clear()
	_value_guide_text.append_text(_build_value_guide_text())

	_prepare_warehouse_grid()
	clear_bid_log()
	set_result_text("请先创建房间或加入房间，等待 2 到 4 名玩家全部准备完毕后开始竞拍。")
	set_connection_status("输入名字后可以直接开房或加入房间。默认使用 127.0.0.1:7000。")
	set_match_active(false)
	update_round_info(0, "等待房间开始")
	update_countdown(-1)

	if not _root.resized.is_connected(_on_outline_layout_changed):
		_root.resized.connect(_on_outline_layout_changed)
	if not _warehouse_grid.resized.is_connected(_on_outline_layout_changed):
		_warehouse_grid.resized.connect(_on_outline_layout_changed)
	if not _root.get_viewport().size_changed.is_connected(_on_outline_layout_changed):
		_root.get_viewport().size_changed.connect(_on_outline_layout_changed)


func setup_players(players: Array[PlayerData]) -> void:
	_clear_container_children(_players_list)
	_player_row_map.clear()

	for player in players:
		var row = _create_player_row(player)
		_players_list.add_child(row)
		_player_row_map[player.player_id] = row

	update_player_panels(players, _local_player_id, _match_active)


func update_room_ui(room_state: Dictionary) -> void:
	_local_player_id = int(room_state.get("local_peer_id", -1))
	_match_active = bool(room_state.get("match_active", false))
	_room_joined = _local_player_id != -1

	var players: Array[Dictionary] = []
	for player_data in room_state.get("players", []):
		players.append(player_data as Dictionary)

	_local_ready = false
	for player_data in players:
		if int(player_data.get("player_id", -1)) == _local_player_id:
			_local_ready = bool(player_data.get("is_ready", false))
			break

	var connected_count = int(room_state.get("connected_count", players.size()))
	var max_players = int(room_state.get("max_players", 4))
	var is_host = bool(room_state.get("is_host", false))

	_host_button.disabled = _room_joined
	_join_button.disabled = _room_joined
	_player_name_edit.editable = not _room_joined
	_host_address_edit.editable = not _room_joined
	_port_spin_box.editable = not _room_joined

	_ready_button.disabled = not _room_joined or _match_active
	_leave_button.disabled = not _room_joined

	if not _room_joined:
		_ready_button.text = "准备"
	elif _match_active:
		_ready_button.text = "对局进行中"
	else:
		_ready_button.text = "取消准备" if _local_ready else "准备"

	if _room_joined:
		var mode_text = "房主" if is_host else "客户端"
		var room_text = "房间人数 %d/%d | %s" % [connected_count, max_players, mode_text]
		if _match_active:
			room_text += " | 对局进行中"
		else:
			room_text += " | 等待全员准备（2-4人可开局）"
		set_connection_status(room_text)


func update_player_panels(players: Array[PlayerData], local_player_id: int = -1, match_active: bool = false) -> void:
	for player in players:
		var row = _player_row_map.get(player.player_id) as Control
		if row == null:
			continue

		var name_label = row.get_node("Margin/VBox/Header/NameLabel") as Label
		var type_tag = row.get_node("Margin/VBox/Header/TypeTag") as Label
		var bid_label = row.get_node("Margin/VBox/BidLabel") as Label
		var score_label = row.get_node("Margin/VBox/ScoreLabel") as Label
		var extra_label = row.get_node("Margin/VBox/ExtraLabel") as Label

		var is_local_player = player.player_id == local_player_id
		name_label.text = player.display_name
		type_tag.text = "你" if is_local_player else "在线"
		type_tag.modulate = PLAYER_LOCAL_COLOR if is_local_player else PLAYER_REMOTE_COLOR
		bid_label.text = "当前公开出价: %d" % player.last_revealed_bid
		score_label.text = "总积分: %d" % player.total_score

		if match_active:
			if player.is_eliminated:
				extra_label.text = "已淘汰 | %s" % player.elimination_reason
			else:
				extra_label.text = "已进入对局"
		else:
			var status_text = "已准备" if player.is_ready else "未准备"
			if player.is_eliminated:
				status_text = "已淘汰"
				if not player.elimination_reason.is_empty():
					status_text += " | %s" % player.elimination_reason
			extra_label.text = "%s | %s" % [status_text, "在线" if player.network_connected else "离线"]


func render_warehouse(public_items: Array[Dictionary], grid_size: Vector2i = Vector2i(20, 20)) -> void:
	_grid_size = grid_size
	_prepare_warehouse_grid()

	var item_by_cell = _build_item_lookup(public_items)

	for y in range(grid_size.y):
		for x in range(grid_size.x):
			var cell_node = _get_grid_cell_node(Vector2i(x, y))
			if cell_node == null:
				continue

			var cell_key = _cell_key(Vector2i(x, y))
			var item_data = item_by_cell.get(cell_key, {})
			var item_id = int(item_data.get("id", 0))
			var occupied = item_id != 0

			var style = StyleBoxFlat.new()
			style.bg_color = GRID_EMPTY_COLOR
			style.border_color = GRID_LINE_COLOR
			style.set_border_width_all(0)
			style.corner_radius_top_left = 0
			style.corner_radius_top_right = 0
			style.corner_radius_bottom_left = 0
			style.corner_radius_bottom_right = 0

			if occupied:
				style.bg_color = GRID_OCCUPIED_COLOR

			cell_node.add_theme_stylebox_override("panel", style)
			cell_node.tooltip_text = ""

			var label = cell_node.get_meta("count_label") as Label
			label.text = ""

	_get_outline_overlay().configure_hidden(grid_size, public_items, HIDDEN_OUTLINE_COLOR, HIDDEN_OUTLINE_WIDTH)


func render_revealed_warehouse(items: Array[ItemData], grid_size: Vector2i = Vector2i(20, 20)) -> void:
	_grid_size = grid_size
	_prepare_warehouse_grid()

	var item_by_cell = _build_revealed_item_lookup(items)

	for y in range(grid_size.y):
		for x in range(grid_size.x):
			var cell_node = _get_grid_cell_node(Vector2i(x, y))
			if cell_node == null:
				continue

			var item = item_by_cell.get(_cell_key(Vector2i(x, y)), null) as ItemData
			var occupied = item != null

			var style = StyleBoxFlat.new()
			style.bg_color = GRID_EMPTY_COLOR
			style.border_color = GRID_LINE_COLOR
			style.set_border_width_all(0)
			style.corner_radius_top_left = 0
			style.corner_radius_top_right = 0
			style.corner_radius_bottom_left = 0
			style.corner_radius_bottom_right = 0

			if occupied:
				style.bg_color = _get_revealed_item_color(item)
				style.shadow_color = Color(0.0, 0.0, 0.0, 0.35)
				style.shadow_size = 2

			cell_node.add_theme_stylebox_override("panel", style)
			cell_node.tooltip_text = "总价值: %d" % item.total_value if occupied else ""

			var label = cell_node.get_meta("count_label") as Label
			label.text = ""

	_get_outline_overlay().configure_revealed(grid_size, items, REVEALED_OUTLINE_WIDTH, ITEM_OUTLINE_PALETTE)


func clear_warehouse() -> void:
	render_warehouse([], _grid_size)


func update_round_info(round_number: int, rule_text: String) -> void:
	if round_number <= 0:
		_round_label.text = "轮次：-"
	else:
		_round_label.text = "第 %d 轮 / 共 6 轮" % round_number
	_rule_label.text = "规则：%s" % rule_text


func update_countdown(seconds_left: int) -> void:
	if seconds_left < 0:
		_countdown_label.text = "倒计时：--"
	else:
		_countdown_label.text = "倒计时：%ds" % seconds_left


func append_bid_log(message: String, color: Color = Color.WHITE) -> void:
	var hex_color = color.to_html(false)
	_bid_log.append_text("[color=#%s]%s[/color]\n" % [hex_color, message])
	_bid_log.scroll_to_line(_bid_log.get_line_count())


func clear_bid_log() -> void:
	_bid_log.clear()


func set_result_text(text: String) -> void:
	_result_text.clear()
	_result_text.append_text(text)


func show_round_result(round_result: Dictionary) -> void:
	var lines: Array[String] = []
	lines.append("第 %d 轮结果" % int(round_result.get("round", 0)))
	lines.append(str(round_result.get("rule_text", "")))
	lines.append("")
	lines.append("公开出价：")

	var revealed_bids = round_result.get("revealed_bids", [])
	for bid_info in revealed_bids:
		lines.append("%s: %d" % [
			str(bid_info.get("display_name", "")),
			int(bid_info.get("bid", 0))
		])

	lines.append("")
	lines.append(str(round_result.get("message", "")))

	if round_result.get("status", "") == "sold":
		lines.append("成交价: %d" % int(round_result.get("winning_bid", 0)))
		lines.append("赢家积分变化: %d" % int(round_result.get("score_delta", 0)))

	set_result_text("\n".join(lines))


func show_final_results(items: Array[ItemData], ranking: Array[Dictionary], auction_summary: String) -> void:
	var lines: Array[String] = []
	lines.append("真实仓库价值揭晓")
	lines.append("")

	for item in items:
		lines.append("物品 #%d | 格数:%d | 品质:%s | 单格:%d | 总值:%d" % [
			item.id,
			item.get_cell_count(),
			item.get_rarity_name(),
			item.unit_value,
			item.total_value
		])

	lines.append("")
	lines.append("玩家排名")
	for index in range(ranking.size()):
		var row = ranking[index]
		lines.append("%d. %s | 总积分:%d | 最后出价:%d" % [
			index + 1,
			str(row.get("display_name", "")),
			int(row.get("total_score", 0)),
			int(row.get("last_bid", 0))
		])

	lines.append("")
	lines.append(auction_summary)
	set_result_text("\n".join(lines))


func set_human_bid_enabled(enabled: bool) -> void:
	_bid_spin_box.editable = enabled
	_submit_bid_button.disabled = not enabled


func set_human_bid_value(value: int) -> void:
	_bid_spin_box.value = value


func get_human_bid_value() -> int:
	return int(_bid_spin_box.value)


func set_connection_status(text: String, color: Color = Color("cbd5e1")) -> void:
	_connection_status_label.text = text
	_connection_status_label.modulate = color


func set_match_active(active: bool) -> void:
	_match_active = active
	_bid_spin_box.editable = false
	_submit_bid_button.disabled = true

	if active:
		_bid_input_label.text = "你的出价"
		_next_round_button.text = "等待服务器结算"
	else:
		_bid_input_label.text = "房间状态"
		_next_round_button.text = "等待房间开始"

	_next_round_button.disabled = true


func _build_value_guide_text() -> String:
	var lines: Array[String] = []
	lines.append("不同品质物品的单格价值参考")
	lines.append("")
	lines.append("红：30000 ~ 200000")
	lines.append("黄：8000 ~ 50000")
	lines.append("紫：6000 ~ 15000")
	lines.append("蓝：5000 ~ 10000")
	lines.append("绿：2000 ~ 8000")
	lines.append("白：1000 ~ 5000")
	lines.append("")
	lines.append("本局通用规则")
	lines.append("")
	lines.append("1. 仓库大小：20 x 20")
	lines.append("2. 物品数量：40 ~ 80")
	lines.append("3. 物品形状：矩形")
	lines.append("4. 单个物品边长不超过 5 格")
	lines.append("5. 红色品质物品有较高概率出现")
	lines.append("")
	lines.append("竞拍提示")
	lines.append("")
	lines.append("1. 你只能看到物品轮廓，无法看到品质与真实价值。")
	lines.append("2. 成交后收益 = 仓库真实总价值 - 成交价格。")
	lines.append("3. 出价过高时，即使成交也可能得到负分。")
	lines.append("4. 大面积物品不一定更值钱，价值仍由隐藏品质决定。")
	return "\n".join(lines)


func _open_value_guide() -> void:
	_value_guide_overlay.visible = true
	_value_guide_text.scroll_to_line(0)


func _close_value_guide() -> void:
	_value_guide_overlay.visible = false


func _on_value_guide_backdrop_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_close_value_guide()


func _on_host_pressed() -> void:
	host_requested.emit(_player_name_edit.text, int(_port_spin_box.value))


func _on_join_pressed() -> void:
	join_requested.emit(
		_player_name_edit.text,
		_host_address_edit.text,
		int(_port_spin_box.value)
	)


func _on_ready_pressed() -> void:
	ready_toggled.emit(not _local_ready)


func _on_leave_pressed() -> void:
	leave_room_requested.emit()


func _on_submit_bid_pressed() -> void:
	human_bid_submitted.emit(get_human_bid_value())


func _create_player_row(player: PlayerData) -> PanelContainer:
	var panel = PanelContainer.new()
	panel.custom_minimum_size = Vector2(0, 84)

	var margin = MarginContainer.new()
	margin.name = "Margin"
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_bottom", 8)
	panel.add_child(margin)

	var vbox = VBoxContainer.new()
	vbox.name = "VBox"
	vbox.add_theme_constant_override("separation", 4)
	margin.add_child(vbox)

	var header = HBoxContainer.new()
	header.name = "Header"
	vbox.add_child(header)

	var name_label = Label.new()
	name_label.name = "NameLabel"
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.text = player.display_name
	header.add_child(name_label)

	var type_tag = Label.new()
	type_tag.name = "TypeTag"
	type_tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	header.add_child(type_tag)

	var bid_label = Label.new()
	bid_label.name = "BidLabel"
	vbox.add_child(bid_label)

	var score_label = Label.new()
	score_label.name = "ScoreLabel"
	vbox.add_child(score_label)

	var extra_label = Label.new()
	extra_label.name = "ExtraLabel"
	extra_label.modulate = Color("cbd5e1")
	vbox.add_child(extra_label)

	return panel


func _prepare_warehouse_grid() -> void:
	_clear_container_children(_warehouse_grid)

	var grid_cells = GridContainer.new()
	grid_cells.name = "GridCells"
	grid_cells.columns = _grid_size.x
	grid_cells.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid_cells.size_flags_vertical = Control.SIZE_EXPAND_FILL
	grid_cells.anchors_preset = Control.PRESET_FULL_RECT
	grid_cells.anchor_right = 1.0
	grid_cells.anchor_bottom = 1.0
	grid_cells.offset_right = 0.0
	grid_cells.offset_bottom = 0.0
	grid_cells.add_theme_constant_override("h_separation", 0)
	grid_cells.add_theme_constant_override("v_separation", 0)
	_warehouse_grid.add_child(grid_cells)
	if not grid_cells.resized.is_connected(_on_outline_layout_changed):
		grid_cells.resized.connect(_on_outline_layout_changed)

	var outline_overlay = WarehouseOutlineOverlay.new()
	outline_overlay.name = "OutlineOverlay"
	outline_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	outline_overlay.position = Vector2.ZERO
	outline_overlay.size = Vector2.ZERO
	_warehouse_grid.add_child(outline_overlay)

	var grid_background = StyleBoxFlat.new()
	grid_background.bg_color = GRID_BACKGROUND_COLOR
	grid_background.corner_radius_top_left = 6
	grid_background.corner_radius_top_right = 6
	grid_background.corner_radius_bottom_left = 6
	grid_background.corner_radius_bottom_right = 6
	_warehouse_grid.add_theme_stylebox_override("panel", grid_background)

	for y in range(_grid_size.y):
		for x in range(_grid_size.x):
			var panel = PanelContainer.new()
			panel.name = "Cell_%d_%d" % [x, y]
			panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
			panel.custom_minimum_size = Vector2(_get_grid_cell_size(), _get_grid_cell_size())

			var center = CenterContainer.new()
			panel.add_child(center)

			var count_label = Label.new()
			count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			count_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			center.add_child(count_label)

			panel.set_meta("grid_position", Vector2i(x, y))
			panel.set_meta("count_label", count_label)
			grid_cells.add_child(panel)

	_get_outline_overlay().clear_overlay()
	_sync_outline_overlay()


func _build_item_lookup(public_items: Array[Dictionary]) -> Dictionary:
	var lookup = {}
	for item_data in public_items:
		var cells = item_data.get("cells", [])
		for cell in cells:
			lookup[_cell_key(cell)] = item_data
	return lookup


func _build_revealed_item_lookup(items: Array[ItemData]) -> Dictionary:
	var lookup = {}
	for item in items:
		for cell in item.cells:
			lookup[_cell_key(cell)] = item
	return lookup


func _neighbor_item_id(cell: Vector2i, item_by_cell: Dictionary) -> int:
	if cell.x < 0 or cell.x >= _grid_size.x or cell.y < 0 or cell.y >= _grid_size.y:
		return -1
	var item_data = item_by_cell.get(_cell_key(cell), {})
	return int(item_data.get("id", 0))


func _neighbor_revealed_item(cell: Vector2i, item_by_cell: Dictionary) -> ItemData:
	if cell.x < 0 or cell.x >= _grid_size.x or cell.y < 0 or cell.y >= _grid_size.y:
		return null
	return item_by_cell.get(_cell_key(cell), null) as ItemData


func _get_revealed_item_color(item: ItemData) -> Color:
	var color = item.get_display_color()
	if item.rarity == ItemData.Rarity.WHITE:
		return Color("bfc7d5")
	return color


func _get_grid_cell_node(cell: Vector2i) -> PanelContainer:
	var grid_cells = _warehouse_grid.get_node_or_null("GridCells") as GridContainer
	if grid_cells == null:
		return null
	return grid_cells.get_node_or_null("Cell_%d_%d" % [cell.x, cell.y])


func _get_outline_overlay() -> WarehouseOutlineOverlay:
	return _warehouse_grid.get_node("OutlineOverlay") as WarehouseOutlineOverlay


func _sync_outline_overlay() -> void:
	if _outline_resync_pending:
		return
	_outline_resync_pending = true
	call_deferred("_run_outline_resync_sequence")


func _on_outline_layout_changed() -> void:
	_sync_outline_overlay()


func _run_outline_resync_sequence() -> void:
	for _step in range(4):
		await get_tree().process_frame
		_deferred_sync_outline_overlay()
	_outline_resync_pending = false


func _deferred_sync_outline_overlay() -> void:
	var grid_cells = _warehouse_grid.get_node_or_null("GridCells") as Control
	var outline_overlay = _get_outline_overlay()
	if grid_cells == null or outline_overlay == null:
		return
	outline_overlay.position = grid_cells.position
	outline_overlay.size = grid_cells.size
	var first_cell = grid_cells.get_node_or_null("Cell_0_0") as Control
	var cell_size = Vector2.ONE
	if first_cell != null:
		cell_size = first_cell.size
	outline_overlay.set_grid_metrics(Vector2.ZERO, cell_size)
	outline_overlay.queue_redraw()


func _get_grid_cell_size() -> float:
	var min_dimension = minf(_warehouse_grid.custom_minimum_size.x, _warehouse_grid.custom_minimum_size.y)
	return maxf(4.0, floor(min_dimension / float(max(_grid_size.x, _grid_size.y))))


func _clear_container_children(container: Node) -> void:
	for child in container.get_children():
		container.remove_child(child)
		child.free()


func _cell_key(cell: Vector2i) -> String:
	return "%d,%d" % [cell.x, cell.y]
