class_name AIPlayer
extends "res://scripts/data/Player.gd"

const ItemData = preload("res://scripts/data/Item.gd")

# AI 玩家：
# 1. 基于公开信息估算仓库价值区间
# 2. 根据风险偏好与当前轮次决定出价
# 3. 不直接读取隐藏价值，保持“盲拍”特性

enum RiskProfile {
	CONSERVATIVE,
	BALANCED,
	AGGRESSIVE
}

const PROFILE_NAMES := {
	RiskProfile.CONSERVATIVE: "保守",
	RiskProfile.BALANCED: "均衡",
	RiskProfile.AGGRESSIVE: "激进"
}

const BASE_RARITY_PROBABILITIES := {
	ItemData.Rarity.RED: 0.03,
	ItemData.Rarity.YELLOW: 0.07,
	ItemData.Rarity.PURPLE: 0.12,
	ItemData.Rarity.BLUE: 0.18,
	ItemData.Rarity.GREEN: 0.24,
	ItemData.Rarity.WHITE: 0.36
}

var rng: RandomNumberGenerator = RandomNumberGenerator.new()
var risk_profile: RiskProfile = RiskProfile.BALANCED
var risk_bias: float = 1.0
var bluff_factor: float = 0.0
var profit_guard_ratio: float = 0.0
var last_estimation: Dictionary = {}


func _init(
	p_player_id: int = -1,
	p_display_name: String = "",
	p_risk_profile: RiskProfile = RiskProfile.BALANCED,
	seed_value: int = -1
) -> void:
	super._init(p_player_id, p_display_name, false)
	risk_profile = p_risk_profile

	match risk_profile:
		RiskProfile.CONSERVATIVE:
			risk_bias = 0.62
			bluff_factor = 0.0
			profit_guard_ratio = 0.18
		RiskProfile.BALANCED:
			risk_bias = 0.74
			bluff_factor = 0.02
			profit_guard_ratio = 0.12
		RiskProfile.AGGRESSIVE:
			risk_bias = 0.86
			bluff_factor = 0.05
			profit_guard_ratio = 0.06

	if seed_value >= 0:
		rng.seed = seed_value
	else:
		rng.randomize()


func estimate_value_range(public_summary: Dictionary) -> Dictionary:
	var total_cells = int(public_summary.get("total_occupied_cells", 0))
	var item_count = int(public_summary.get("item_count", 0))
	var shape_sizes = public_summary.get("shape_sizes", [])
	var average_size = 0.0

	if item_count > 0:
		average_size = float(total_cells) / float(item_count)

	var rarity_probabilities = _build_adjusted_rarity_probabilities(total_cells, average_size, item_count)
	var expected_unit_value = 0.0
	var conservative_unit_value = 0.0
	var optimistic_unit_value = 0.0

	for rarity_key in rarity_probabilities.keys():
		var probability = float(rarity_probabilities[rarity_key])
		var value_range: Vector2i = ItemData.get_unit_value_range(rarity_key)
		var range_min = float(value_range.x)
		var range_max = float(value_range.y)
		var range_mid = (range_min + range_max) * 0.5

		expected_unit_value += range_mid * probability
		conservative_unit_value += lerpf(range_min, range_mid, 0.35) * probability
		optimistic_unit_value += lerpf(range_mid, range_max, 0.65) * probability

	var shape_bonus_multiplier = _estimate_shape_bonus(shape_sizes, average_size)
	expected_unit_value *= shape_bonus_multiplier
	conservative_unit_value *= max(0.82, shape_bonus_multiplier - 0.08)
	optimistic_unit_value *= shape_bonus_multiplier + 0.12

	# AI 默认保守处理未知信息，主动给估值打折，减少高价买入亏损。
	conservative_unit_value *= 0.82
	expected_unit_value *= 0.9
	optimistic_unit_value *= 0.96

	var estimated_min = int(round(conservative_unit_value * total_cells))
	var estimated_expected = int(round(expected_unit_value * total_cells))
	var estimated_max = int(round(optimistic_unit_value * total_cells))

	last_estimation = {
		"estimated_min": estimated_min,
		"estimated_expected": estimated_expected,
		"estimated_max": max(estimated_max, estimated_expected),
		"expected_unit_value": expected_unit_value,
		"average_shape_size": average_size,
		"total_cells": total_cells,
		"item_count": item_count,
		"rarity_probabilities": rarity_probabilities
	}

	return last_estimation.duplicate(true)


func generate_bid(
	public_summary: Dictionary,
	round_number: int,
	revealed_bids: Array[Dictionary] = []
) -> int:
	var estimation = estimate_value_range(public_summary)
	var estimated_min = int(estimation["estimated_min"])
	var estimated_expected = int(estimation["estimated_expected"])
	var estimated_max = int(estimation["estimated_max"])

	var round_pressure = _get_round_pressure(round_number)
	var safe_reference_value = _get_safe_reference_value(estimated_min, estimated_expected, estimated_max)
	var target_ratio = (0.82 + round_pressure * 0.08) * risk_bias
	var variance_ratio = rng.randf_range(-0.05, 0.04)
	var target_bid = int(round(float(safe_reference_value) * (target_ratio + variance_ratio)))
	var safe_ceiling = _get_safe_ceiling(estimated_min, estimated_expected, estimated_max, round_number)
	var minimum_bid_floor = 0
	var previous_bid = last_revealed_bid

	if risk_profile == RiskProfile.CONSERVATIVE:
		minimum_bid_floor = int(estimated_min * 0.6)
		safe_ceiling = maxi(safe_ceiling, minimum_bid_floor)
		target_bid = clampi(target_bid, minimum_bid_floor, safe_ceiling)
	elif risk_profile == RiskProfile.BALANCED:
		minimum_bid_floor = int(estimated_min * 0.7)
		safe_ceiling = maxi(safe_ceiling, minimum_bid_floor)
		target_bid = clampi(target_bid, minimum_bid_floor, safe_ceiling)
	else:
		minimum_bid_floor = int(estimated_min * 0.76)
		safe_ceiling = maxi(safe_ceiling, minimum_bid_floor)
		target_bid = clampi(target_bid, minimum_bid_floor, safe_ceiling)

	var current_highest_bid = _get_current_highest_bid(revealed_bids)
	var is_current_leader = previous_bid > 0 and previous_bid >= current_highest_bid
	target_bid = _adapt_to_competition(
		target_bid,
		current_highest_bid,
		estimated_min,
		estimated_expected,
		estimated_max,
		round_number,
		safe_ceiling,
		previous_bid,
		is_current_leader
	)
	target_bid = _adjust_for_round_progression(
		target_bid,
		current_highest_bid,
		previous_bid,
		safe_ceiling,
		round_number,
		is_current_leader
	)
	target_bid = maxi(0, target_bid)

	set_bid(target_bid)
	return target_bid


func get_profile_name() -> String:
	return PROFILE_NAMES.get(risk_profile, "未知")


func get_last_estimation_text() -> String:
	if last_estimation.is_empty():
		return "%s 尚未完成估值。" % display_name

	return "%s[%s] 估值区间: %d ~ %d，期望值: %d" % [
		display_name,
		get_profile_name(),
		int(last_estimation.get("estimated_min", 0)),
		int(last_estimation.get("estimated_max", 0)),
		int(last_estimation.get("estimated_expected", 0))
	]


func _build_adjusted_rarity_probabilities(total_cells: int, average_size: float, item_count: int) -> Dictionary:
	var probabilities = BASE_RARITY_PROBABILITIES.duplicate()

	# 总占用格子越多，AI 越愿意相信仓库中存在更高价值组合。
	if total_cells >= 50:
		probabilities[ItemData.Rarity.RED] += 0.01
		probabilities[ItemData.Rarity.YELLOW] += 0.02
		probabilities[ItemData.Rarity.PURPLE] += 0.02
		probabilities[ItemData.Rarity.WHITE] -= 0.05
	elif total_cells <= 30:
		probabilities[ItemData.Rarity.WHITE] += 0.04
		probabilities[ItemData.Rarity.GREEN] += 0.02
		probabilities[ItemData.Rarity.RED] -= 0.01
		probabilities[ItemData.Rarity.YELLOW] -= 0.02
		probabilities[ItemData.Rarity.PURPLE] -= 0.01

	# 平均形状越大，AI 认为高价值大件概率略高。
	if average_size >= 6.0:
		probabilities[ItemData.Rarity.RED] += 0.01
		probabilities[ItemData.Rarity.YELLOW] += 0.01
		probabilities[ItemData.Rarity.PURPLE] += 0.02
		probabilities[ItemData.Rarity.WHITE] -= 0.04
	elif average_size <= 3.0:
		probabilities[ItemData.Rarity.WHITE] += 0.03
		probabilities[ItemData.Rarity.GREEN] += 0.02
		probabilities[ItemData.Rarity.RED] -= 0.01
		probabilities[ItemData.Rarity.YELLOW] -= 0.02
		probabilities[ItemData.Rarity.BLUE] -= 0.02

	# 物品数量偏多时，AI 偏向估计中低档货混装。
	if item_count >= 12:
		probabilities[ItemData.Rarity.WHITE] += 0.03
		probabilities[ItemData.Rarity.GREEN] += 0.02
		probabilities[ItemData.Rarity.RED] -= 0.01
		probabilities[ItemData.Rarity.YELLOW] -= 0.01
		probabilities[ItemData.Rarity.PURPLE] -= 0.01
		probabilities[ItemData.Rarity.BLUE] -= 0.02

	return _normalize_probability_dict(probabilities)


func _normalize_probability_dict(probabilities: Dictionary) -> Dictionary:
	var normalized = {}
	var total = 0.0

	for key in probabilities.keys():
		var value = max(0.005, float(probabilities[key]))
		normalized[key] = value
		total += value

	if total <= 0.0:
		return BASE_RARITY_PROBABILITIES.duplicate()

	for key in normalized.keys():
		normalized[key] = float(normalized[key]) / total

	return normalized


func _estimate_shape_bonus(shape_sizes: Array, average_size: float) -> float:
	var large_shape_count = 0
	for size_value in shape_sizes:
		if int(size_value) >= 7:
			large_shape_count += 1

	var bonus = 1.0
	bonus += min(0.04, average_size * 0.005)
	bonus += min(0.03, float(large_shape_count) * 0.01)
	return bonus


func _get_round_pressure(round_number: int) -> float:
	match round_number:
		1:
			return 0.0
		2:
			return 0.1
		3:
			return 0.18
		4:
			return 0.28
		5:
			return 0.42
		6:
			return 0.55
		_:
			return 0.0


func _get_safe_reference_value(estimated_min: int, estimated_expected: int, estimated_max: int) -> int:
	match risk_profile:
		RiskProfile.CONSERVATIVE:
			return int(round(lerpf(float(estimated_min), float(estimated_expected), 0.15)))
		RiskProfile.BALANCED:
			return int(round(lerpf(float(estimated_min), float(estimated_expected), 0.3)))
		RiskProfile.AGGRESSIVE:
			return int(round(lerpf(float(estimated_expected), float(estimated_max), 0.08)))
		_:
			return estimated_expected


func _get_safe_ceiling(estimated_min: int, estimated_expected: int, estimated_max: int, round_number: int) -> int:
	var late_round_bonus = 1.0 + _get_round_pressure(round_number) * 0.05
	var ceiling_value = estimated_expected

	match risk_profile:
		RiskProfile.CONSERVATIVE:
			ceiling_value = int(round(min(
				float(estimated_expected) * (0.82 + late_round_bonus * 0.02),
				float(estimated_min) * (1.0 - profit_guard_ratio) + float(estimated_expected) * 0.12
			)))
		RiskProfile.BALANCED:
			ceiling_value = int(round(min(
				float(estimated_expected) * (0.9 + late_round_bonus * 0.03),
				float(estimated_min) * (1.0 - profit_guard_ratio) + float(estimated_expected) * 0.22
			)))
		RiskProfile.AGGRESSIVE:
			ceiling_value = int(round(min(
				float(estimated_expected) * (0.96 + late_round_bonus * 0.03),
				float(estimated_max) * 0.88
			)))
		_:
			ceiling_value = estimated_expected

	return maxi(0, ceiling_value)


func _get_current_highest_bid(revealed_bids: Array[Dictionary]) -> int:
	var highest = 0
	for bid_info in revealed_bids:
		highest = maxi(highest, int(bid_info.get("bid", 0)))
	return highest


func _adapt_to_competition(
	target_bid: int,
	current_highest_bid: int,
	estimated_min: int,
	estimated_expected: int,
	estimated_max: int,
	round_number: int,
	safe_ceiling: int,
	previous_bid: int,
	is_current_leader: bool
) -> int:
	if current_highest_bid <= 0:
		return target_bid

	var minimum_raise = 200 + round_number * 100
	var challenge_bid = current_highest_bid + minimum_raise
	var max_acceptable_bid = mini(
		safe_ceiling,
		int(round(lerpf(float(estimated_min), float(estimated_expected), 0.5 + bluff_factor)))
	)

	if current_highest_bid >= safe_ceiling:
		return maxi(min(previous_bid, safe_ceiling), int(round(float(maxi(estimated_min, 0)) * 0.92)))

	if challenge_bid <= max_acceptable_bid and round_number >= 3:
		return maxi(target_bid, challenge_bid)

	if is_current_leader and previous_bid > 0:
		return mini(max(previous_bid, target_bid), safe_ceiling)

	if current_highest_bid > estimated_expected:
		return mini(target_bid, max_acceptable_bid)

	return mini(maxi(target_bid, current_highest_bid), max_acceptable_bid)


func _adjust_for_round_progression(
	target_bid: int,
	current_highest_bid: int,
	previous_bid: int,
	safe_ceiling: int,
	round_number: int,
	is_current_leader: bool
) -> int:
	var adjusted_bid = target_bid
	var increment_step = _get_round_increment_step(round_number)

	if previous_bid <= 0:
		return mini(adjusted_bid, safe_ceiling)

	if is_current_leader:
		# 领先时通常保持价格稳定，仅在后期小幅上调，避免被低成本反超。
		if round_number >= 4 and previous_bid < safe_ceiling:
			adjusted_bid = min(safe_ceiling, max(adjusted_bid, previous_bid + int(round(increment_step * 0.45))))
		else:
			adjusted_bid = max(adjusted_bid, previous_bid)
		return mini(adjusted_bid, safe_ceiling)

	# 落后时在后几轮尝试逐步追价，但始终不突破安全上限。
	if round_number >= 2 and current_highest_bid < safe_ceiling:
		var catch_up_bid = min(safe_ceiling, max(current_highest_bid + increment_step, previous_bid + increment_step))
		adjusted_bid = max(adjusted_bid, catch_up_bid)

	# 若已经逼近安全上限，则保持小幅试探，不再大幅抬价。
	if safe_ceiling - adjusted_bid <= int(round(increment_step * 0.75)):
		adjusted_bid = min(safe_ceiling, max(adjusted_bid, previous_bid))

	return mini(adjusted_bid, safe_ceiling)


func _get_round_increment_step(round_number: int) -> int:
	match round_number:
		1:
			return 400
		2:
			return 800
		3:
			return 1400
		4:
			return 2200
		5:
			return 3200
		6:
			return 4500
		_:
			return 1000
