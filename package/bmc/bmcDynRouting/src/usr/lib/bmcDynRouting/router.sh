# Router ID: thuộc tính chung của router (section "global"), FRR đặt ở mức zebra để mọi giao thức dùng chung.

load_router() {
	router_id=$(uci_get bmcDynRouting.global.router_id)
}

router_id_invalid='Router ID must be a valid dotted-quad'
router_id_missing='Router ID is required when OSPF or BGP is enabled: set it with "router-id set --router-id ID"'

# OSPF và BGP cần Router ID; RIP thì không.
router_id_required() {
	[ "$ospf_enabled" = 1 ] || [ "$bgp_enabled" = 1 ]
}

# Lỗi của Router ID đang lưu (OSPF và BGP cần nó), hoặc không in gì.
router_id_error() {
	if [ -z "$router_id" ]; then
		printf '%s' "$router_id_missing"
	elif ! ipv4_valid "$router_id"; then
		printf '%s' "$router_id_invalid"
	fi
}

# Tạo section chung trong batch nếu cấu hình (vd. từ phase 1) chưa có.
batch_add_global_section() {
	if [ -z "$(uci_get bmcDynRouting.global)" ]; then batch_add 'set bmcDynRouting.global=global'; fi
}

router_id_get() {
	reply 0 'Router ID' ",\"router_id\":$(json_string "$router_id")"
}

# router-id set --router-id ID: ghi Router ID rồi apply. Chuỗi rỗng xoá Router ID, chỉ khi không giao thức nào cần.
router_id_set() {
	if [ "$#" -ne 2 ] || [ "$1" != --router-id ]; then
		fail router_id 'usage: router-id set --router-id ID'
		return
	fi
	if [ -n "$2" ] && ! ipv4_valid "$2"; then
		fail router_id "$router_id_invalid"
		return
	fi
	if [ -z "$2" ] && router_id_required; then
		fail router_id "$router_id_missing"
		return
	fi
	batch_reset
	batch_add_global_section
	batch_add "set bmcDynRouting.global.router_id=$(uci_quote "$2")"
	save_and_apply 'Router ID saved' ''
}

# Nâng cấp từ phase 1 (uci-defaults gọi): Router ID nằm ở bmcDynRouting.ospf.router_id. Chuyển nó sang
# section chung nếu ở đó chưa có Router ID, rồi xoá option cũ. Chạy lại trên cấu hình đã chuyển không đổi gì.
migrate() {
	batch_reset
	old_router_id=$(uci_get bmcDynRouting.ospf.router_id)
	batch_add_global_section
	if [ -z "$router_id" ] && [ -n "$old_router_id" ]; then
		batch_add "set bmcDynRouting.global.router_id=$(uci_quote "$old_router_id")"
	fi
	if uci_has bmcDynRouting.ospf.router_id; then batch_add 'delete bmcDynRouting.ospf.router_id'; fi
	if [ -z "$uci_batch" ]; then
		reply 0 'configuration already migrated'
		return
	fi
	plan_or_commit 'configuration migrated' '' bmcDynRouting || return 0
	reply 0 'configuration migrated'
}
