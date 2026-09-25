class_name CardCatalog
extends RefCounted
## Factory definitions used only to initialize the shared writable library.

const CARDS: Dictionary = {
	"std_infantry": {"name": "标准步兵", "unit_type": "infantry", "deploy_cost": 1, "action_cost": 1, "attack": 2, "max_hp": 2},
	"std_artillery": {"name": "标准火炮", "unit_type": "artillery", "deploy_cost": 3, "action_cost": 1, "attack": 2, "max_hp": 3},
	"std_fighter": {"name": "标准战斗机", "unit_type": "fighter", "deploy_cost": 3, "action_cost": 1, "attack": 3, "max_hp": 3},
	"std_bomber": {"name": "标准轰炸机", "unit_type": "bomber", "deploy_cost": 4, "action_cost": 2, "attack": 5, "max_hp": 6},
	"raid_infantry": {"name": "突袭步兵", "unit_type": "infantry", "deploy_cost": 2, "action_cost": 1, "attack": 2, "max_hp": 2, "keywords": {"raid": true}},
	"raid_tank": {"name": "突袭坦克", "unit_type": "tank", "deploy_cost": 3, "action_cost": 1, "attack": 3, "max_hp": 2, "keywords": {"raid": true}},
	"raid_fighter": {"name": "突袭战斗机", "unit_type": "fighter", "deploy_cost": 4, "action_cost": 1, "attack": 3, "max_hp": 4, "keywords": {"raid": true}},
	"guard_infantry": {"name": "掩护步兵", "unit_type": "infantry", "deploy_cost": 2, "action_cost": 1, "attack": 1, "max_hp": 4, "keywords": {"guard": true}},
	"armor_tank": {"name": "装甲坦克", "unit_type": "tank", "deploy_cost": 4, "action_cost": 2, "attack": 4, "max_hp": 5, "keywords": {"armor": 1}},
	"deploy_draw_infantry": {"name": "部署步兵", "unit_type": "infantry", "deploy_cost": 3, "action_cost": 1, "attack": 2, "max_hp": 3, "abilities": [{"id": "deploy_draw", "trigger": "deploy", "effects": [{"op": "draw", "target": "owner", "amount": 1}]}]},
	"deploy_damage_artillery": {"name": "部署火炮", "unit_type": "artillery", "deploy_cost": 4, "action_cost": 2, "attack": 3, "max_hp": 3, "abilities": [{"id": "deploy_damage", "trigger": "deploy", "effects": [{"op": "damage", "target": "chosen_enemy_unit", "amount": 2}]}]},
	"aftermath_draw_infantry": {"name": "余波步兵", "unit_type": "infantry", "deploy_cost": 2, "action_cost": 1, "attack": 2, "max_hp": 2, "abilities": [{"id": "aftermath_draw", "trigger": "aftermath", "effects": [{"op": "draw", "target": "owner", "amount": 1}]}]},
	"aftermath_heal_tank": {"name": "余波坦克", "unit_type": "tank", "deploy_cost": 2, "action_cost": 1, "attack": 2, "max_hp": 2, "abilities": [{"id": "aftermath_heal", "trigger": "aftermath", "effects": [{"op": "heal", "target": "owner_hq", "amount": 3}]}]},
	"aftermath_support_infantry": {"name": "余波协同步兵", "unit_type": "infantry", "deploy_cost": 4, "action_cost": 2, "attack": 2, "max_hp": 6, "auras": [{"kind": "aftermath_twice"}]},
	"order_damage": {"card_type": "order", "name": "打击指令", "deploy_cost": 1, "abilities": [{"id": "play_damage", "trigger": "play", "effects": [{"op": "damage", "target": "chosen_enemy_unit", "amount": 2}]}]},
	"order_row_damage": {"card_type": "order", "name": "轰击指令", "deploy_cost": 2, "abilities": [{"id": "play_row_damage", "trigger": "play", "effects": [{"op": "damage", "target": "chosen_enemy_row", "amount": 1}]}]},
	"order_draw": {"card_type": "order", "name": "补给指令", "deploy_cost": 2, "abilities": [{"id": "play_draw", "trigger": "play", "effects": [{"op": "draw", "target": "owner", "amount": 2}]}]},
	"order_heal": {"card_type": "order", "name": "恢复指令", "deploy_cost": 1, "abilities": [{"id": "play_heal", "trigger": "play", "effects": [{"op": "heal", "target": "chosen_friendly", "amount": 3}]}]},
	"order_buff": {"card_type": "order", "name": "强化指令", "deploy_cost": 2, "abilities": [{"id": "play_buff", "trigger": "play", "effects": [{"op": "modify_stats", "target": "chosen_friendly_unit", "attack": 1, "health": 2}]}]},
	"order_suppress": {"card_type": "order", "name": "压制指令", "deploy_cost": 1, "abilities": [{"id": "play_suppress", "trigger": "play", "effects": [{"op": "suppress", "target": "chosen_enemy_unit"}]}]},
}
const PRESET: Array[String] = [
	"std_infantry", "std_infantry", "std_artillery", "std_artillery",
	"std_fighter", "std_fighter", "std_bomber", "std_bomber",
	"raid_infantry", "raid_infantry", "raid_tank", "raid_tank", "raid_fighter", "raid_fighter",
	"guard_infantry", "guard_infantry", "armor_tank", "armor_tank",
	"deploy_draw_infantry", "deploy_draw_infantry", "deploy_damage_artillery", "deploy_damage_artillery",
	"aftermath_draw_infantry", "aftermath_draw_infantry", "aftermath_heal_tank", "aftermath_heal_tank",
	"aftermath_support_infantry", "aftermath_support_infantry",
	"order_damage", "order_damage", "order_row_damage", "order_row_damage", "order_draw", "order_draw",
	"order_heal", "order_heal", "order_buff", "order_buff", "order_suppress", "order_suppress",
]
const TYPE_NAMES: Dictionary = {
	"infantry": "步兵", "tank": "坦克", "artillery": "火炮",
	"fighter": "战斗机", "bomber": "轰炸机",
}
const TYPE_DESCRIPTIONS: Dictionary = {
	"infantry": "近程：支援线可攻击敌前线，前线可攻击敌支援与总部。每回合移动或攻击一次。",
	"tank": "近程：支援线可攻击敌前线，前线可攻击敌支援与总部。每回合可移动一次并攻击一次，顺序不限。",
	"artillery": "远程：可攻击任意敌方场上目标，攻击时不受反击。每回合移动或攻击一次。",
	"fighter": "远程：可攻击任意敌方场上目标。阻止敌方轰炸机攻击同一阵线的友军目标（战斗机除外）。每回合移动或攻击一次。",
	"bomber": "远程：可攻击任意敌方场上目标，攻击时仅战斗机会反击，自身不能反击。须先攻击目标同排的敌方战斗机。每回合移动或攻击一次。",
}


static func card(card_id: String) -> Dictionary:
	if not CARDS.has(card_id):
		return {}
	var result: Dictionary = CARDS[card_id].duplicate(true)
	result.merge({"card_type": "unit", "keywords": {}, "abilities": [], "auras": []}, false)
	result["card_id"] = card_id
	return result


static func preset_deck() -> Array[String]:
	return PRESET.duplicate()


static func type_name(unit_type: String) -> String:
	return str(TYPE_NAMES.get(unit_type, unit_type))


static func type_description(unit_type: String) -> String:
	return str(TYPE_DESCRIPTIONS.get(unit_type, ""))
