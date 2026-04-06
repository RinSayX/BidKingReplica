class_name WarehouseGenerator
extends RefCounted

const ItemData = preload("res://scripts/data/Item.gd")

# 仓库生成器：
# 1. 生成 20x20 网格
# 2. 随机生成多个互不重叠的物品
# 3. 仅生成矩形物品
# 4. 输出完整隐藏数据与公开轮廓数据

const GRID_SIZE := Vector2i(20, 20)
const MIN_ITEM_SIZE := 1
const MAX_ITEM_SIZE := 12
const MAX_ITEM_SIDE_LENGTH := 5
const MIN_ITEM_COUNT := 40
const MAX_ITEM_COUNT := 80
const TARGET_FILL_RATIO_MIN := 0.38
const TARGET_FILL_RATIO_MAX := 0.62

const RARITY_WEIGHTS := {
	ItemData.Rarity.RED: 3,
	ItemData.Rarity.YELLOW: 7,
	ItemData.Rarity.PURPLE: 12,
	ItemData.Rarity.BLUE: 20,
	ItemData.Rarity.GREEN: 24,
	ItemData.Rarity.WHITE: 34
}

const RED_AVAILABLE_CHANCE := 0.95

var rng: RandomNumberGenerator = RandomNumberGenerator.new()
var current_match_allows_red: bool = false


func _init(seed_value: int = -1) -> void:
	if seed_value >= 0:
		rng.seed = seed_value
	else:
		rng.randomize()


func set_seed(seed_value: int) -> void:
	rng.seed = seed_value


func generate_warehouse() -> Dictionary:
	current_match_allows_red = rng.randf() < RED_AVAILABLE_CHANCE

	var occupancy = _create_empty_occupancy()
	var items: Array[ItemData] = []
	var occupied_cells = 0
	var target_fill_ratio = rng.randf_range(TARGET_FILL_RATIO_MIN, TARGET_FILL_RATIO_MAX)
	var target_fill_cells = int(round(float(GRID_SIZE.x * GRID_SIZE.y) * target_fill_ratio))
	var desired_item_count = rng.randi_range(MIN_ITEM_COUNT, MAX_ITEM_COUNT)

	var item_id = 1
	var safety_counter = 0
	while item_id <= desired_item_count and safety_counter < 300:
		safety_counter += 1

		var remaining_cells = (GRID_SIZE.x * GRID_SIZE.y) - occupied_cells
		if remaining_cells <= 0:
			break

		var max_size_for_now = mini(MAX_ITEM_SIZE, remaining_cells)
		if max_size_for_now <= 0:
			break

		var preferred_max_size = mini(max_size_for_now, max(1, target_fill_cells - occupied_cells))
		var item_size = _roll_item_size(preferred_max_size, max_size_for_now)
		var shape_cells = _try_build_item_shape(item_size, occupancy)
		if shape_cells.is_empty():
			continue

		var rarity = _roll_rarity()
		var item = ItemData.create_random(item_id, shape_cells, rng, rarity)
		if not item.is_valid():
			continue

		items.append(item)
		_mark_cells(shape_cells, occupancy, item_id)
		occupied_cells += shape_cells.size()
		item_id += 1

		if occupied_cells >= target_fill_cells and items.size() >= MIN_ITEM_COUNT:
			break

	if items.size() < MIN_ITEM_COUNT:
		_try_fill_missing_items(items, occupancy, occupied_cells, target_fill_cells, item_id)

	return {
		"grid_size": GRID_SIZE,
		"items": items,
		"occupied_map": occupancy,
		"occupied_cell_count": _count_occupied_cells(occupancy),
		"total_value": calculate_total_value(items),
		"public_items": get_public_item_data(items)
	}


func get_public_item_data(items: Array[ItemData]) -> Array[Dictionary]:
	var public_data: Array[Dictionary] = []
	for item in items:
		public_data.append(item.to_public_dict())
	return public_data


func calculate_total_value(items: Array[ItemData]) -> int:
	var total = 0
	for item in items:
		total += item.total_value
	return total


func get_total_occupied_cells(items: Array[ItemData]) -> int:
	var total = 0
	for item in items:
		total += item.get_cell_count()
	return total


func build_public_summary(items: Array[ItemData]) -> Dictionary:
	var shape_sizes: Array[int] = []
	for item in items:
		shape_sizes.append(item.get_cell_count())

	return {
		"grid_size": GRID_SIZE,
		"item_count": items.size(),
		"total_occupied_cells": get_total_occupied_cells(items),
		"shape_sizes": shape_sizes
	}


func debug_dump(items: Array[ItemData]) -> String:
	var lines: Array[String] = []
	lines.append("Warehouse %dx%d | item_count=%d | total_value=%d" % [
		GRID_SIZE.x,
		GRID_SIZE.y,
		items.size(),
		calculate_total_value(items)
	])

	for item in items:
		lines.append(item.get_debug_summary())

	return "\n".join(lines)


func _try_fill_missing_items(
	items: Array[ItemData],
	occupancy: Array,
	occupied_cells: int,
	target_fill_cells: int,
	starting_item_id: int
) -> void:
	var next_id = starting_item_id
	var local_occupied_cells = occupied_cells
	var emergency_counter = 0

	while items.size() < MIN_ITEM_COUNT and emergency_counter < 200:
		emergency_counter += 1

		var remaining_cells = (GRID_SIZE.x * GRID_SIZE.y) - local_occupied_cells
		if remaining_cells <= 0:
			break

		var preferred_max_size = mini(4, remaining_cells)
		var item_size = _roll_item_size(preferred_max_size, preferred_max_size)
		var shape_cells = _try_build_item_shape(item_size, occupancy)
		if shape_cells.is_empty():
			continue

		var rarity = _roll_rarity()
		var item = ItemData.create_random(next_id, shape_cells, rng, rarity)
		if not item.is_valid():
			continue

		items.append(item)
		_mark_cells(shape_cells, occupancy, next_id)
		local_occupied_cells += shape_cells.size()
		next_id += 1

		if local_occupied_cells >= target_fill_cells and items.size() >= MIN_ITEM_COUNT:
			break


func _roll_item_size(preferred_max_size: int, hard_max_size: int) -> int:
	var actual_max = maxi(1, mini(MAX_ITEM_SIZE, hard_max_size))
	var preferred_max = maxi(1, mini(actual_max, preferred_max_size))
	var should_bias_small = rng.randf() < 0.7

	if should_bias_small:
		return rng.randi_range(1, preferred_max)
	return rng.randi_range(1, actual_max)


func _roll_rarity() -> ItemData.Rarity:
	var total_weight = 0
	for rarity_key in RARITY_WEIGHTS.keys():
		if rarity_key == ItemData.Rarity.RED and not current_match_allows_red:
			continue
		total_weight += int(RARITY_WEIGHTS[rarity_key])

	var roll = rng.randi_range(1, total_weight)
	var cumulative = 0

	for rarity_key in RARITY_WEIGHTS.keys():
		if rarity_key == ItemData.Rarity.RED and not current_match_allows_red:
			continue
		cumulative += int(RARITY_WEIGHTS[rarity_key])
		if roll <= cumulative:
			return rarity_key

	return ItemData.Rarity.WHITE


func _try_build_item_shape(target_size: int, occupancy: Array) -> Array[Vector2i]:
	var attempts = 0
	while attempts < 40:
		attempts += 1

		var shape_cells: Array[Vector2i] = _build_rectangle_shape(target_size, occupancy)

		if shape_cells.size() == target_size and _are_cells_all_free(shape_cells, occupancy):
			return shape_cells

	return []


func _build_rectangle_shape(target_size: int, occupancy: Array) -> Array[Vector2i]:
	var anchor_cell = _find_next_free_cell(occupancy)
	if anchor_cell == Vector2i(-1, -1):
		return []

	var factor_pairs: Array[Vector2i] = []
	for width in range(1, target_size + 1):
		if target_size % width != 0:
			continue
		@warning_ignore("integer_division")
		var height = int(target_size / width)
		if (
			width <= GRID_SIZE.x and
			height <= GRID_SIZE.y and
			width <= MAX_ITEM_SIDE_LENGTH and
			height <= MAX_ITEM_SIDE_LENGTH
		):
			factor_pairs.append(Vector2i(width, height))

	if factor_pairs.is_empty():
		return []

	factor_pairs.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		if a.x == b.x:
			return a.y < b.y
		return a.x > b.x
	)

	for pair in factor_pairs:
		if anchor_cell.x + pair.x > GRID_SIZE.x or anchor_cell.y + pair.y > GRID_SIZE.y:
			continue

		var cells = _build_rectangle_cells(anchor_cell, pair, occupancy)
		if cells.size() == target_size:
			return cells

	return []


func _find_next_free_cell(occupancy: Array) -> Vector2i:
	for y in range(GRID_SIZE.y):
		for x in range(GRID_SIZE.x):
			if occupancy[y][x] == 0:
				return Vector2i(x, y)
	return Vector2i(-1, -1)


func _build_rectangle_cells(start: Vector2i, size: Vector2i, occupancy: Array) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []

	for local_y in range(size.y):
		for local_x in range(size.x):
			var cell = start + Vector2i(local_x, local_y)
			if not _is_cell_free(cell, occupancy):
				return []
			cells.append(cell)

	return cells

func _is_in_bounds(cell: Vector2i) -> bool:
	return cell.x >= 0 and cell.x < GRID_SIZE.x and cell.y >= 0 and cell.y < GRID_SIZE.y


func _is_cell_free(cell: Vector2i, occupancy: Array) -> bool:
	if not _is_in_bounds(cell):
		return false
	return occupancy[cell.y][cell.x] == 0


func _are_cells_all_free(cells: Array[Vector2i], occupancy: Array) -> bool:
	for cell in cells:
		if not _is_cell_free(cell, occupancy):
			return false
	return true

func _mark_cells(cells: Array[Vector2i], occupancy: Array, item_id: int) -> void:
	for cell in cells:
		occupancy[cell.y][cell.x] = item_id


func _create_empty_occupancy() -> Array:
	var occupancy: Array = []
	for y in range(GRID_SIZE.y):
		var row: Array[int] = []
		for x in range(GRID_SIZE.x):
			row.append(0)
		occupancy.append(row)
	return occupancy


func _count_occupied_cells(occupancy: Array) -> int:
	var count = 0
	for row in occupancy:
		for value in row:
			if value != 0:
				count += 1
	return count


func _cell_key(cell: Vector2i) -> String:
	return "%d,%d" % [cell.x, cell.y]
