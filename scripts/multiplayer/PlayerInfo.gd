extends RefCounted

static func create(id: int, player_name: String, ip_address: String = "127") -> Dictionary:
	return {
		"id": id,
		"name": player_name,
		"ip_address": ip_address,
	}
