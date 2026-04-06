class_name Item
extends RefCounted

# 仓库中的隐藏物品数据类。
# 只保存数据与基础规则，不负责生成和显示。

enum Rarity {
	RED,
	YELLOW,
	PURPLE,
	BLUE,
	GREEN,
	WHITE
}

const RARITY_NAMES := {
	Rarity.RED: "红",
	Rarity.YELLOW: "黄",
	Rarity.PURPLE: "紫",
	Rarity.BLUE: "蓝",
	Rarity.GREEN: "绿",
	Rarity.WHITE: "白"
}

const RARITY_UNIT_VALUE_RANGES := {
	Rarity.RED: Vector2i(30000, 200000),
	Rarity.YELLOW: Vector2i(8000, 50000),
	Rarity.PURPLE: Vector2i(6000, 15000),
	Rarity.BLUE: Vector2i(5000, 10000),
	Rarity.GREEN: Vector2i(2000, 8000),
	Rarity.WHITE: Vector2i(1000, 5000)
}

const RARITY_DISPLAY_COLORS := {
	Rarity.RED: Color("d94b4b"),
	Rarity.YELLOW: Color("d9b43b"),
	Rarity.PURPLE: Color("8b5cf6"),
	Rarity.BLUE: Color("3b82f6"),
	Rarity.GREEN: Color("22c55e"),
	Rarity.WHITE: Color("d4d4d8")
}

var id: int = -1
var cells: Array[Vector2i] = []
var rarity: Rarity = Rarity.WHITE
var unit_value: int = 1000
var total_value: int = 1000


func _init(
	p_id: int = -1,
	p_cells: Array[Vector2i] = [],
	p_rarity: Rarity = Rarity.WHITE,
	p_unit_value: int = 1000
) -> void:
	id = p_id
	cells = p_cells.duplicate()
	rarity = p_rarity
	var value_range: Vector2i = RARITY_UNIT_VALUE_RANGES.get(p_rarity, Vector2i(1000, 5000))
	unit_value = clampi(p_unit_value, value_range.x, value_range.y)
	total_value = unit_value * get_cell_count()


func get_cell_count() -> int:
	return cells.size()


func get_bounds() -> Rect2i:
	if cells.is_empty():
		return Rect2i()

	var min_x: int = cells[0].x
	var min_y: int = cells[0].y
	var max_x: int = cells[0].x
	var max_y: int = cells[0].y

	for cell in cells:
		min_x = min(min_x, cell.x)
		min_y = min(min_y, cell.y)
		max_x = max(max_x, cell.x)
		max_y = max(max_y, cell.y)

	return Rect2i(min_x, min_y, max_x - min_x + 1, max_y - min_y + 1)


func contains_cell(cell: Vector2i) -> bool:
	return cells.has(cell)


func is_valid() -> bool:
	if id < 0:
		return false
	if cells.is_empty():
		return false
	if not RARITY_UNIT_VALUE_RANGES.has(rarity):
		return false

	var unique_cells = {}
	for cell in cells:
		var key = "%s,%s" % [cell.x, cell.y]
		if unique_cells.has(key):
			return false
		unique_cells[key] = true

	var allowed_range: Vector2i = RARITY_UNIT_VALUE_RANGES.get(rarity, Vector2i(1000, 5000))
	return unit_value >= allowed_range.x and unit_value <= allowed_range.y


func to_public_dict() -> Dictionary:
	return {
		"id": id,
		"cells": cells.duplicate(),
		"cell_count": get_cell_count()
	}


func to_full_dict() -> Dictionary:
	return {
		"id": id,
		"cells": cells.duplicate(),
		"cell_count": get_cell_count(),
		"rarity": rarity,
		"rarity_name": get_rarity_name(),
		"unit_value": unit_value,
		"total_value": total_value
	}


func get_rarity_name() -> String:
	return RARITY_NAMES.get(rarity, "未知")


func get_display_color() -> Color:
	return RARITY_DISPLAY_COLORS.get(rarity, Color.WHITE)


func get_debug_summary() -> String:
	return "Item #%d | 格数:%d | 品质:%s | 单格:%d | 总值:%d" % [
		id,
		get_cell_count(),
		get_rarity_name(),
		unit_value,
		total_value
	]


static func create_random(
	p_id: int,
	p_cells: Array[Vector2i],
	p_rng: RandomNumberGenerator,
	p_rarity: Rarity = Rarity.WHITE
) -> Item:
	var value_range: Vector2i = RARITY_UNIT_VALUE_RANGES.get(p_rarity, Vector2i(1000, 5000))
	var rolled_value = p_rng.randi_range(value_range.x, value_range.y)
	return new(p_id, p_cells, p_rarity, rolled_value)


static func from_full_dict(data: Dictionary):
	var parsed_cells: Array[Vector2i] = []
	for cell_value in data.get("cells", []):
		if cell_value is Vector2i:
			parsed_cells.append(cell_value as Vector2i)
		else:
			var cell_dict = cell_value as Dictionary
			parsed_cells.append(Vector2i(
				int(cell_dict.get("x", 0)),
				int(cell_dict.get("y", 0))
			))

	return new(
		int(data.get("id", -1)),
		parsed_cells,
		int(data.get("rarity", Rarity.WHITE)),
		int(data.get("unit_value", 1000))
	)


static func get_unit_value_range(p_rarity: Rarity) -> Vector2i:
	return RARITY_UNIT_VALUE_RANGES.get(p_rarity, Vector2i(1000, 5000))
