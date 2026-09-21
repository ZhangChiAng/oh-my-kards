class_name BattleRuleConfig
extends Resource
## Match parameters. Approved values live in resources/rules/approved_rules.tres.

@export var hq_max_hp: int
@export var first_hand_count: int
@export var second_hand_count: int
@export var hand_limit: int
@export var support_limit: int
@export var frontline_limit: int
@export var command_point_growth: int
@export var command_point_limit: int
@export var turn_draw_count: int
@export var fatigue_initial: int
@export var fatigue_increment: int
@export var player_mulligan_seed_salt: int
@export var ai_mulligan_seed_salt: int
