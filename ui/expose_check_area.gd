@tool
extends GraphEdit

const PopupHelper = preload("res://addons/expose_check/ui/popup_helper.gd")
const ScriptAnalyzer = preload("res://addons/expose_check/ui/script_analyzer.gd")
const BlueprintIO = preload("res://addons/expose_check/ui/blueprint_io.gd")

#GraphEditor左上角的位置
var graphe_leftup_corner_pos:Vector2:
	get:
		return Vector2(0.0,get_window().size.y-get_rect().size.y)
var _mouse_in_ge_pos:Vector2 = Vector2.ZERO
var _mouse_in_graph_area_pos:Vector2 = Vector2.ZERO
var _current_node:Array[ExposeCheck_ScriptNode] = []

##节点 key → 节点。
##顶层类的 key 就是脚本路径；内部类是 "脚本路径::内部类名"（再嵌套就继续接 ::）。
##父类递归查重、继承接线、之后的刷新都靠它。
var _node_by_key:Dictionary[String,ExposeCheck_ScriptNode] = {}

##连线来源表。
##GraphEdit 的连线不带元数据，只能自己记 —— 否则刷新时没法区分
##「脚本自动生成的继承边」和「用户手拉的线」。
##每条：{ "from": 父/起点节点 key, "to": 子/终点节点 key, "semantic": "inherit" | "user" }
var _edges:Array[Dictionary] = []

##继承节点往左推时的列距（要大于一个节点宽度，不然还是叠在一起）
const ANCESTOR_COL_GAP := 340.0
##继承链最多往上找这么多层，防循环
const MAX_ANCESTOR_DEPTH := 64
##内部类挂到外类下面时的行距
const INNER_ROW_GAP := 260.0

##转发给面板：图上节点块的左键注释请求 / 右键更换端口定义请求
signal hint_requested(hint_string:String,at_position:Vector2)
signal port_menu_requested(block:ExposeCheck_ContainerBlock,at_position:Vector2)

func _enter_tree() -> void:
	_init_file_window()
	_init_json_window()
	if import_mode_menu != null:
		import_mode_menu.id_pressed.connect(_on_import_mode_id_pressed)
	#脚本文件被改动 → 只重新比对 md5 改状态色，绝不自动重建（刷不刷由用户按按钮决定）
	EditorInterface.get_resource_filesystem().filesystem_changed.connect(_on_fs_changed)

func _on_disconnection_request(from_node: StringName, from_port: int, to_node: StringName, to_port: int) -> void:
	var from_key := _key_of_node(from_node)
	var to_key := _key_of_node(to_node)
	disconnect_node(from_node,from_port,to_node,to_port)
	_forget_edge(from_key,to_key)




func _on_connection_request(from_node: StringName, from_port: int, to_node: StringName, to_port: int) -> void:
	#只有相同端口类型才许连：0 是父类专属，1..N 是自定义端口。
	#这一道拦截不是重复劳动：add_valid_connection_type 只在拖拽时起作用，
	#connect_node() 完全不校验类型（实测类型 2 -> 1 照样返回 OK）。
	var ft := _port_type_of(from_node,from_port,true)
	var tt := _port_type_of(to_node,to_port,false)
	if ft < 0 or ft != tt:
		push_warning(ExposeCheck_I18n.t("expose_check: 端口类型不匹配（%d -> %d），这条线不允许") % [ft,tt])
		return
	if connect_node(from_node,from_port,to_node,to_port) != OK:
		return
	_edges.append({
		"from": _key_of_node(from_node),
		"to": _key_of_node(to_node),
		"semantic": "user",
	})

#region 浮动面板相关
var _fd: EditorFileDialog
const editor_file_dialog_ratio:float = 0.4
@export var float_menu:PopupMenu
##导入时问「清空重建 / 合并 / 取消」的选单
@export var import_mode_menu:PopupMenu

##蓝图用的文件对话框（导出和导入共用一个，用之前先设 file_mode）
var _json_fd: EditorFileDialog
##0 = 导出全部，1 = 保存选中，2 = 导入
var _json_mode: int = 0
##已经读进来、等着用户选导入模式的那份文档
var _pending_import: Dictionary = {}
const json_dialog_ratio:float = 0.5

func _init_file_window()->void:
	_fd = EditorFileDialog.new()
	_fd.file_mode = FileDialog.FILE_MODE_OPEN_FILE      # 见下方模式表
	_fd.access = FileDialog.ACCESS_RESOURCES            # 限制在 res://
	_fd.add_filter("*.gd", "Script")            # 注意是「逗号」分隔
	_fd.current_dir = "res://"
	_fd.file_selected.connect(_on_file_selected)
	add_child(_fd)
	
func _exit_tree() -> void:
	_fd.queue_free()
	if _json_fd != null:
		_json_fd.queue_free()
	var efs = EditorInterface.get_resource_filesystem()
	if efs.filesystem_changed.is_connected(_on_fs_changed):
		efs.filesystem_changed.disconnect(_on_fs_changed)


##蓝图用的文件对话框。常驻实例，导出/导入只是换 file_mode。
func _init_json_window()->void:
	_json_fd = EditorFileDialog.new()
	_json_fd.access = FileDialog.ACCESS_RESOURCES
	_json_fd.add_filter("*.json", ExposeCheck_I18n.t("蓝图"))
	_json_fd.current_dir = "res://"
	_json_fd.current_file = "expose_blueprint.json"
	_json_fd.file_selected.connect(_on_json_file_selected)
	add_child(_json_fd)

func _on_file_selected(script_path: String) -> void:
	#路径不存在就什么都不做：不报错、不建节点、不改状态色
	if not ScriptAnalyzer.file_exists(script_path):
		push_warning(ExposeCheck_I18n.t("expose_check: 找不到脚本文件 ") + script_path)
		return
	create_node_for_path(script_path,_mouse_in_graph_area_pos)


## 同名的 .gd 出现第二个时，两个节点都改用完整路径当标题，否则图上看不出区别。
## 旧节点也要置位，不然它下次重建又会退回短名。
func _mark_short_name_collision(info:ExposeCheck_ScriptInfo) -> void:
	for node in _current_node:
		if node.script_info == null or node.script_info.file_name == info.file_name:
			continue
		if node.script_info.short_name == info.short_name:
			info.is_same_short_name = true
			node.script_info.is_same_short_name = true
			node.title = node.script_info.file_name
#endregion

var script_node_scene:PackedScene=preload("res://addons/expose_check/ui/ScriptNode.tscn")


## 视口坐标 → GraphEdit 图坐标。
## GraphElement 的图内位置是 position_offset，关系是：视觉位置 = position_offset * zoom - scroll_offset，
## 反解就是 (视口坐标 - GraphEdit 左上角 + scroll_offset) / zoom。
## 注意 GraphEdit 没提供现成的转换函数；缩放那一项请用 0.5 / 2.0 各验一次。
func _screen_to_graph(screen_pos:Vector2)->Vector2:
	return (screen_pos - global_position + scroll_offset) / zoom


##按脚本路径建节点（已有就复用），并把祖先链和内部类都补齐
func create_node_for_path(path:String,at:Vector2) -> ExposeCheck_ScriptNode:
	var node := _get_or_create_by_key(path,at)
	if node != null:
		ensure_ancestors(node)
		ensure_inner_classes(node)
	return node


##内部类也是类：把外类暴露出来的内部类也建成节点，并递归下去。
##建出来之后不在这里接线，交给 ensure_ancestors —— 父是谁由 ExposeCheck_ScriptInfo.father_node_key 决定
##（写了 extends 就是那个基类，没写才是外类）。
func ensure_inner_classes(node:ExposeCheck_ScriptNode) -> void:
	if node == null or node.script_info == null:
		return
	var i := 0
	for name in node.script_info.expose_inner_class.keys():
		var inner_key := "%s::%s" % [node.get_node_key(),String(name)]
		#往下排：祖先已经往左推了，内部类再往左会和祖先撞在一起
		var at := node.position_offset + Vector2(0.0,INNER_ROW_GAP * (i + 1))
		var inner := _get_or_create_by_key(inner_key,at)
		if inner != null:
			#父是谁完全交给 father_node_key 决定：写了 extends 就是那个基类，没写才是外类。
			#这里不能再无条件 _link_inherit(node,inner) —— 那会把 extends 的关系盖成外类。
			ensure_ancestors(inner)
			ensure_inner_classes(inner)
		i += 1


func create_graph_node_from_info(script_info:ExposeCheck_ScriptInfo)->void:
	if script_info == null:
		return
	create_node_for_path(String(script_info.node_key),_mouse_in_graph_area_pos)


##节点 key → ExposeCheck_ScriptInfo。
##顶层 key 就是脚本路径；内部类是 "脚本路径::内部类名"，顺着一层层往里取。
func _info_for_key(key:String) -> ExposeCheck_ScriptInfo:
	var parts := key.split("::")
	if not ScriptAnalyzer.file_exists(parts[0]):
		push_warning(ExposeCheck_I18n.t("expose_check: 找不到脚本文件 ") + parts[0])
		return null
	var info = ScriptAnalyzer.analyze(parts[0])
	for i in range(1,parts.size()):
		if info == null:
			return null
		info = info.expose_inner_class.get(StringName(parts[i]))
		if info == null:
			push_warning(ExposeCheck_I18n.t("expose_check: 找不到内部类 ") + key)
			return null
	return info


##按 key 取节点；没有就分析出 ExposeCheck_ScriptInfo 再建。解析不出来（文件/内部类不存在）返回 null。
func _get_or_create_by_key(key:String,at:Vector2) -> ExposeCheck_ScriptNode:
	if _node_by_key.has(key) and is_instance_valid(_node_by_key[key]):
		return _node_by_key[key]
	var info := _info_for_key(key)
	if info == null:
		return null
	_mark_short_name_collision(info)
	var node:ExposeCheck_ScriptNode = script_node_scene.instantiate() as ExposeCheck_ScriptNode
	node.create_from_script_info(info)
	add_child(node)
	# 必须写 position_offset：写 position 的话，GraphEdit 下一次布局会用 position_offset（默认 0,0）
	# 把它覆盖掉，节点就永远停在左上角。
	node.position_offset = at
	node.hint_requested.connect(hint_requested.emit)
	node.port_menu_requested.connect(port_menu_requested.emit)
	node.refresh_requested.connect(refresh_node)
	node.port_type_changed.connect(_drop_invalid_connections)
	_current_node.append(node)
	_node_by_key[key] = node
	return node


##向上递归补齐父类节点，直到基类不是用户自定义类。
##已经存在的父类节点只接线，不重建。
##内部类的父由 ExposeCheck_ScriptInfo.father_node_key 决定：写了 extends 就是那个基类，没写就是外类。
func ensure_ancestors(node:ExposeCheck_ScriptNode) -> void:
	var child := node
	var level := 1
	while child != null:
		var parent_key := child.get_father_node_key()
		if parent_key == "":
			break                                   # 基类是原生类，到头了
		#往左推：继承箭头是「父右 -> 子左」，父类排在子类左边，链路读起来顺。
		#想改成往右推，把负号去掉即可。
		var at := node.position_offset + Vector2(-ANCESTOR_COL_GAP * level,0.0)
		var parent_node := _get_or_create_by_key(parent_key,at)
		if parent_node == null:
			break                                   # 父类解析不出来，停在这里
		_link_inherit(parent_node,child)
		child = parent_node
		level += 1
		if level > MAX_ANCESTOR_DEPTH:
			push_warning(ExposeCheck_I18n.t("expose_check: 继承链超过 %d 层，疑似循环，已停止") % MAX_ANCESTOR_DEPTH)
			break


##父类右端口 → 子类左端口，都落在 FatherSolt 那一行
func _link_inherit(parent_node:ExposeCheck_ScriptNode,child_node:ExposeCheck_ScriptNode) -> void:
	if parent_node == null or child_node == null:
		return
	#注意：connect_node 的 port 参数是【端口编号】，不是槽位号。
	#端口只数启用了端口的那几行，所以 FatherSolt（slot 1）的编号其实是 0 ——
	#直接传槽位号 1 会越界，而且它还返回 OK，属于静默错连。
	var out_port := parent_node.output_port_of_slot(ExposeCheck_ScriptNode.FATHER_ROW)
	var in_port := child_node.input_port_of_slot(ExposeCheck_ScriptNode.FATHER_ROW)
	if is_node_connected(parent_node.name,out_port,child_node.name,in_port):
		return
	var err := connect_node(parent_node.name,out_port,child_node.name,in_port)
	if err != OK:
		push_warning(ExposeCheck_I18n.t("expose_check: 继承接线失败 %s -> %s (err=%d)") % [parent_node.name,child_node.name,err])
		return
	_edges.append({
		"from": parent_node.get_node_key(),
		"to": child_node.get_node_key(),
		"semantic": "inherit",
	})


##节点名 → 节点 key；找不到返回 ""
##不用 NodePath 查：Godot 自动生成的节点名带 @，走 NodePath 解析容易出意外。
func _key_of_node(node_name:StringName) -> String:
	for n in _current_node:
		if is_instance_valid(n) and n.name == node_name:
			return n.get_node_key()
	return ""


##从来源表里去掉一条边
func _forget_edge(from_key:String,to_key:String) -> void:
	for i in range(_edges.size() - 1,-1,-1):
		if _edges[i]["from"] == from_key and _edges[i]["to"] == to_key:
			_edges.remove_at(i)


##去掉某个节点涉及的所有连线记录
func _forget_edges_of(key:String) -> void:
	for i in range(_edges.size() - 1,-1,-1):
		if _edges[i]["from"] == key or _edges[i]["to"] == key:
			_edges.remove_at(i)


#region 刷新
##刷新一个节点：重读脚本 → 重新分析 → 重建 → 把用户的端口定义和连线复原回来。
##任何一步失败都尽早返回，尽量不留半成品。
func refresh_node(node:ExposeCheck_ScriptNode) -> void:
	if node == null or not is_instance_valid(node) or not _current_node.has(node):
		return
	var key := node.get_node_key()
	var path := node.get_script_path()
	#路径不存在 → 什么都不做（不报错、不改色、不重建）
	if path == "" or not ScriptAnalyzer.file_exists(path):
		return
	#快照：连线（语义端点）+ 用户选的端口定义
	var links := _snapshot_links(node)
	var saved_ports := node.snapshot_port_types()
	#重新分析。失败就原样不动。
	var info := _info_for_key(key)
	if info == null:
		push_warning(ExposeCheck_I18n.t("expose_check: 重新分析失败，节点未刷新 ") + key)
		return
	#显式断开本节点涉及的所有连线。
	#GraphEdit 不会自己清理失效连线：行数一变端口号就错位，旧线会残留并指向错的行。
	_disconnect_all(node)
	#重建
	_mark_short_name_collision(info)
	node.create_from_script_info(info)
	#复原端口定义（成员没了的会留警告）
	node.refresh_port_settings()
	node.restore_port_types(saved_ports)
	#复原用户连线。继承边不从这里恢复 —— 下面按新的 father_node_key 重新推导。
	_restore_links(links)
	#继承关系可能变了：自己的父重推，挂在自己下面的子和内部类重连
	ensure_ancestors(node)
	_relink_children(node)
	ensure_inner_classes(node)
	node.update_dirty_state()


##全局刷新：只处理脏节点（md5 和记录不符的）
func refresh_dirty_nodes() -> void:
	var done := 0
	#复制一份再遍历：refresh_node 会往 _current_node 里加节点（祖先 / 内部类）
	for node in _current_node.duplicate():
		if not is_instance_valid(node):
			continue
		#不能用 := ：duplicate() 返回的是无类型 Array，node 是 Variant，
		#从 Variant 推类型是解析错误（不是警告），整个脚本会编译不过。
		var path = node.get_script_path()
		if path == "" or not ScriptAnalyzer.file_exists(path):
			continue
		if ScriptAnalyzer.file_md5(path) != node.script_md5:
			refresh_node(node)
			done += 1
	print(ExposeCheck_I18n.t("expose_check: 全局刷新，处理了 %d 个脏节点") % done)


##脚本文件有变动 → 只重新比对 md5 改状态色，绝不自动重建
func _on_fs_changed() -> void:
	for node in _current_node:
		if is_instance_valid(node):
			node.update_dirty_state()


##断开某个节点涉及的所有连线，并清掉来源表里对应的记录
func _disconnect_all(node:ExposeCheck_ScriptNode) -> void:
	var nl := node.name
	for c in get_connection_list():
		if c["from_node"] == nl or c["to_node"] == nl:
			disconnect_node(c["from_node"],c["from_port"],c["to_node"],c["to_port"])
	_forget_edges_of(node.get_node_key())


##一个端点记成语义形式：节点 key + 成员身份（固定行只记槽位）+ 左右
func _endpoint_of(node_name:StringName,port:int,is_output:bool) -> Dictionary:
	var key := _key_of_node(node_name)
	var ep := {"key":key,"kind":"","name":"","slot":-1,"side":("right" if is_output else "left")}
	var n = _node_by_key.get(key)
	if n == null:
		return ep
	var slot = n.output_slot_of_port(port) if is_output else n.input_slot_of_port(port)
	ep["slot"] = slot
	if slot >= ExposeCheck_ScriptNode.FIXED_ROW_COUNT:
		var m:Dictionary = n.member_at_slot(slot)
		ep["kind"] = m["kind"]
		ep["name"] = m["name"]
	return ep


##语义端点 → 现在的端口编号；对应的成员已经没了返回 -1
func _port_of_endpoint(ep:Dictionary) -> int:
	var n = _node_by_key.get(ep["key"])
	if n == null:
		return -1
	var slot:int = ep["slot"]
	if String(ep["kind"]) != "":
		slot = n.find_slot(String(ep["kind"]),String(ep["name"]))
		if slot < 0:
			return -1
	if slot < 0:
		return -1
	return n.output_port_of_slot(slot) if ep["side"] == "right" else n.input_port_of_slot(slot)


#region 端口类型
##规则：
##   0      = 父类专属，只有 FatherSolt 那一行用，成员行不许用
##   1..N   = 自定义端口，N = 设置面板里的定义条数，类型 t ↔ _port_defs[t-1]
##   **只有相同类型才能连**，0 和任何自定义类型都不通
##
##两处一起做才算数：
##   1) refresh_valid_connection_types() 注册给 GraphEdit —— 让【拖拽】连不上
##   2) _on_connection_request() 里再拦一道 —— 因为 connect_node() 根本不校验类型
##另外 valid_connection_types 为空时 GraphEdit 放行一切，这才是之前「随便连」的原因。
const MAX_PORT_TYPE := 64

##取某个端口（按端口编号）的类型；取不到返回 -1
func _port_type_of(node_name:StringName,port:int,is_output:bool) -> int:
	return _port_type_at(_node_by_key.get(_key_of_node(node_name)),port,is_output)


##同上，直接给节点。node 为 null、或者槽位取不到，都返回 -1。
func _port_type_at(node,port:int,is_output:bool) -> int:
	if node == null:
		return -1
	var slot:int = node.output_slot_of_port(port) if is_output else node.input_slot_of_port(port)
	if slot < 0:
		return -1
	return node.get_slot_type_right(slot) if is_output else node.get_slot_type_left(slot)


##某个块的端口类型变了：把这一行上类型已经对不上的连线断掉。
##GraphEdit 从不自动清理失效连线，不断的话会留下一条「类型不符但还画着」的线。
func _drop_invalid_connections(node:ExposeCheck_ScriptNode,row:int) -> void:
	if node == null or not is_instance_valid(node):
		return
	var want_out := node.get_slot_type_right(row)
	var want_in := node.get_slot_type_left(row)
	var dropped := 0
	for c in get_connection_list():
		var is_from:bool = c["from_node"] == node.name
		var is_to:bool = c["to_node"] == node.name
		if not is_from and not is_to:
			continue
		var bad := false
		if is_from and node.output_slot_of_port(c["from_port"]) == row:
			bad = _port_type_at(_node_by_key.get(_key_of_node(c["to_node"])),c["to_port"],false) != want_out
		elif is_to and node.input_slot_of_port(c["to_port"]) == row:
			bad = _port_type_at(_node_by_key.get(_key_of_node(c["from_node"])),c["from_port"],true) != want_in
		if not bad:
			continue
		var from_key := _key_of_node(c["from_node"])
		var to_key := _key_of_node(c["to_node"])
		disconnect_node(c["from_node"],c["from_port"],c["to_node"],c["to_port"])
		_forget_edge(from_key,to_key)
		dropped += 1
	if dropped > 0:
		push_warning(ExposeCheck_I18n.t("expose_check: 端口类型变了，这一行上 %d 条对不上的连线已断开") % dropped)


func _config_panel()->Node:
	if owner == null:
		return null
	return owner.get_node_or_null(^"%ConfigPanel")


##合法的自定义端口类型是 1..返回值（至少 1：成员行默认就是类型 1）
func _max_port_type()->int:
	var n := 0
	var cp := _config_panel()
	if cp != null and cp.has_method("get_port_definitions"):
		n = cp.get_port_definitions().size()
	return maxi(1,n)


##把「同类型才可连」注册给 GraphEdit。
##设置里的定义增删之后必须重新注册，否则拖拽限制会和实际端口类型对不上。
func refresh_valid_connection_types()->void:
	#先把旧的清掉：GraphEdit 没有「清空全部」的接口，只能自己按范围删
	for t in range(0,MAX_PORT_TYPE + 1):
		if is_valid_connection_type(t,t):
			remove_valid_connection_type(t,t)
	var top := _max_port_type()
	for t in range(0,top + 1):
		add_valid_connection_type(t,t)
	print(ExposeCheck_I18n.t("expose_check: 端口类型 0..%d 之间同类型可连") % top)
#endregion


##把本节点涉及的连线记成语义端点。
##继承边跳过：它由 ensure_ancestors 按新的 father_node_key 重新推导，
##不能从快照恢复，否则父类改了还会接回旧的。
func _snapshot_links(node:ExposeCheck_ScriptNode) -> Array[Dictionary]:
	var out:Array[Dictionary] = []
	var k := node.get_node_key()
	for c in get_connection_list():
		var from_key := _key_of_node(c["from_node"])
		var to_key := _key_of_node(c["to_node"])
		if from_key != k and to_key != k:
			continue
		if _edge_semantic(from_key,to_key) == "inherit":
			continue
		out.append({
			"from": _endpoint_of(c["from_node"],c["from_port"],true),
			"to": _endpoint_of(c["to_node"],c["to_port"],false),
		})
	return out


##按语义端点重连。有一端已经不存在就丢弃并留一条警告（只 push_warning，不弹窗）
func _restore_links(links:Array[Dictionary]) -> void:
	for l in links:
		var from_ep:Dictionary = l["from"]
		var to_ep:Dictionary = l["to"]
		var from_port := _port_of_endpoint(from_ep)
		var to_port := _port_of_endpoint(to_ep)
		if from_port < 0 or to_port < 0:
			push_warning(ExposeCheck_I18n.t("expose_check: 连线的一端已不存在（%s.%s -> %s.%s），这条线没有恢复") % [
				from_ep["key"],from_ep["name"],to_ep["key"],to_ep["name"]])
			continue
		var fn = _node_by_key.get(from_ep["key"])
		var tn = _node_by_key.get(to_ep["key"])
		if fn == null or tn == null:
			continue
		if connect_node(fn.name,from_port,tn.name,to_port) == OK:
			_edges.append({"from":from_ep["key"],"to":to_ep["key"],"semantic":"user"})


##_disconnect_all 会把「挂在本节点下面的子和内部类」的继承边也断掉，
##但它们的父没变，这里补回来。
func _relink_children(node:ExposeCheck_ScriptNode) -> void:
	var k := node.get_node_key()
	for child_key in _node_by_key.keys():
		var child = _node_by_key[child_key]
		if not is_instance_valid(child) or child == node:
			continue
		if child.get_father_node_key() == k:
			_link_inherit(node,child)


##查一条连线是谁生成的；没有记录就当用户手拉的
func _edge_semantic(from_key:String,to_key:String) -> String:
	for e in _edges:
		if e["from"] == from_key and e["to"] == to_key:
			return e["semantic"]
	return "user"
#endregion


#region 蓝图导出 / 导入
##把图上的节点和连线打包成蓝图文档。
##only_selected = true 时只收选中的节点，以及两端都在集合里的连线。
func export_blueprint(only_selected:bool) -> Dictionary:
	var doc := BlueprintIO.new_doc()
	var picked:Dictionary[String,ExposeCheck_ScriptNode] = {}
	for node in _current_node:
		if not is_instance_valid(node):
			continue
		if only_selected and not node.selected:
			continue
		picked[node.get_node_key()] = node
		var inner := ""
		var cls := ""
		if node.script_info != null:
			inner = String(node.script_info.inner_name)
			cls = String(node.script_info.class_name_string)
		doc["nodes"].append({
			"key": node.get_node_key(),
			"script_path": node.get_script_path(),
			"inner_name": inner,
			"class_name": cls,
			"title": node.title,
			"script_md5": node.script_md5,
			"position": [node.position_offset.x,node.position_offset.y],
			"size": [node.size.x,node.size.y],
			"port_types": node.snapshot_port_types(),
			"members": _members_data(node.script_info),
		})
	#连线用语义端点：节点 key + 成员身份 + 左右。端口号会随成员增删漂移，不能存。
	for c in get_connection_list():
		var from_key := _key_of_node(c["from_node"])
		var to_key := _key_of_node(c["to_node"])
		if not picked.has(from_key) or not picked.has(to_key):
			continue
		doc["links"].append({
			"from": _endpoint_of(c["from_node"],c["from_port"],true),
			"to": _endpoint_of(c["to_node"],c["to_port"],false),
			"semantic": _edge_semantic(from_key,to_key),
		})
	doc["port_definitions"] = _port_definitions_data()
	doc["view"] = {"zoom": zoom,"scroll": [scroll_offset.x,scroll_offset.y]}
	return doc


##端口定义导成纯数据。颜色用 #rrggbbaa —— JSON 存不了 Color。
func _port_definitions_data() -> Array:
	var out := []
	var cp := _config_panel()
	if cp == null or not cp.has_method("get_port_definitions"):
		return out
	for info in cp.get_port_definitions():
		out.append({
			"left": info.left_mean,
			"right": info.right_mean,
			"color": BlueprintIO.color_to_hex(info.color),
		})
	return out


##把节点当前暴露的成员列出来（种类 + 名字 + 注释）。
##蓝图必须能独立描述「这个类对外长什么样」—— 只存个脚本路径让读的人自己再去分析，
##那蓝图就不成其为蓝图，也没法拿它反过来改脚本。
func _members_data(info:ExposeCheck_ScriptInfo) -> Array:
	var out := []
	if info == null:
		return out
	for kind in ExposeCheck_ScriptInfo.KIND_TABLE:
		var items = info.get(kind["field"])
		if items == null:
			continue
		for item in items:
			out.append({
				#写 ASCII 的 id，不是中文显示名 —— 蓝图是交换格式，不能带本地化文本
				"kind": kind["id"],
				"name": String(item.expose_name),
				"hint": item.Dsharp_hint,
				#签名：CLI 按蓝图在脚本里生成代码存根时要原样抄回去
				"params": Array(item.params),
				"ret_type": item.ret_type,
				"prefix": item.prefix,
			})
	return out


##把蓝图里的端口定义灌回设置面板，并重新注册合法端口类型。
##必须在建节点之前做：节点的端口颜色和类型都是从这张表来的。
func _apply_port_definitions(defs:Array) -> void:
	var cp := _config_panel()
	if cp == null or not cp.has_method("set_port_definitions"):
		push_warning(ExposeCheck_I18n.t("expose_check: 找不到设置面板，端口定义没有恢复"))
		return
	cp.set_port_definitions(defs)
	refresh_valid_connection_types()
	print(ExposeCheck_I18n.t("expose_check: 已恢复 %d 条端口定义") % defs.size())


##把蓝图灌进图里。mode: 0 = 清空重建，1 = 合并进现有图。
##先建完全部节点再连线 —— connect_node 是按节点名查子节点的。
func apply_blueprint(doc:Dictionary,mode:int) -> void:
	var nodes:Array = doc.get("nodes",[])
	var links:Array = doc.get("links",[])
	#端口定义先恢复：节点的端口颜色和类型都是按这张表套的，晚一步就全错
	var defs = doc.get("port_definitions",null)
	if typeof(defs) == TYPE_ARRAY and defs.size() > 0:
		_apply_port_definitions(defs)
	if mode == 0:
		clear_all_nodes()
	var mismatch := 0
	for entry in nodes:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var key := String(entry.get("key",""))
		if key == "":
			continue
		var at := Vector2.ZERO
		var pos = entry.get("position",null)
		if typeof(pos) == TYPE_ARRAY and pos.size() == 2:
			at = Vector2(float(pos[0]),float(pos[1]))
		var node := _get_or_create_by_key(key,at)
		if node == null:
			push_warning(ExposeCheck_I18n.t("expose_check: 蓝图里的节点建不出来，跳过 ") + key)
			continue
		node.position_offset = at
		var sz = entry.get("size",null)
		if typeof(sz) == TYPE_ARRAY and sz.size() == 2:
			node.size = Vector2(float(sz[0]),float(sz[1]))
		node.refresh_port_settings()
		var pts = entry.get("port_types",null)
		if typeof(pts) == TYPE_DICTIONARY:
			node.restore_port_types(pts)
		var want_md5 := String(entry.get("script_md5",""))
		if want_md5 != "" and want_md5 != node.script_md5:
			mismatch += 1
	for l in links:
		if typeof(l) == TYPE_DICTIONARY:
			_apply_link(l)
	var view = doc.get("view",null)
	if typeof(view) == TYPE_DICTIONARY:
		if view.has("zoom"):
			zoom = float(view["zoom"])
		var sc = view.get("scroll",null)
		if typeof(sc) == TYPE_ARRAY and sc.size() == 2:
			scroll_offset = Vector2(float(sc[0]),float(sc[1]))
	print(ExposeCheck_I18n.t("expose_check: 导入完成，%d 个节点 / %d 条线") % [nodes.size(),links.size()])
	if mismatch > 0:
		push_warning(ExposeCheck_I18n.t("expose_check: 有 %d 个节点的脚本在导出之后被改过，成员可能对不上") % mismatch)


##按语义端点接一条线；有一端不存在就丢弃并留警告
func _apply_link(l:Dictionary) -> void:
	var from_ep = l.get("from",null)
	var to_ep = l.get("to",null)
	if typeof(from_ep) != TYPE_DICTIONARY or typeof(to_ep) != TYPE_DICTIONARY:
		return
	var from_port := _port_of_endpoint(from_ep)
	var to_port := _port_of_endpoint(to_ep)
	if from_port < 0 or to_port < 0:
		push_warning(ExposeCheck_I18n.t("expose_check: 蓝图里的一条线端点不存在（%s -> %s），跳过") % [
			BlueprintIO.endpoint_label(from_ep),BlueprintIO.endpoint_label(to_ep)])
		return
	var fn = _node_by_key.get(BlueprintIO.endpoint_key(from_ep))
	var tn = _node_by_key.get(BlueprintIO.endpoint_key(to_ep))
	if fn == null or tn == null:
		return
	if connect_node(fn.name,from_port,tn.name,to_port) != OK:
		return
	_edges.append({
		"from": BlueprintIO.endpoint_key(from_ep),
		"to": BlueprintIO.endpoint_key(to_ep),
		"semantic": String(l.get("semantic","user")),
	})


##删掉图上所有节点
func clear_all_nodes() -> void:
	clear_connections()
	for node in _current_node.duplicate():
		if is_instance_valid(node):
			node.free()
	_current_node.clear()
	_node_by_key.clear()
	_edges.clear()
	print(ExposeCheck_I18n.t("expose_check: 已清空全部节点"))


##导出全部 / 保存选中 / 导入 —— 三个入口共用这一个文件对话框
func _ask_json_path(mode:int) -> void:
	if _json_fd == null:
		return
	_json_mode = mode
	_json_fd.file_mode = FileDialog.FILE_MODE_OPEN_FILE if mode == 2 else FileDialog.FILE_MODE_SAVE_FILE
	_json_fd.popup_centered_ratio(json_dialog_ratio)


func _on_json_file_selected(path:String) -> void:
	if _json_mode == 2:
		var doc := BlueprintIO.load_from_file(path)
		if doc.is_empty():
			return
		_pending_import = doc
		_ask_import_mode()
		return
	var only_selected := _json_mode == 1
	var out := export_blueprint(only_selected)
	if BlueprintIO.save_to_file(path,out) == OK:
		print(ExposeCheck_I18n.t("expose_check: 已写出 %d 个节点（选中范围=%s）到 %s") % [
			out["nodes"].size(),str(only_selected),path])


##导入前先问一句：清空重建还是合并。每次都问，不替你决定。
func _ask_import_mode() -> void:
	if import_mode_menu == null:
		#没有选单就直接清空重建，别把文件白读了
		apply_blueprint(_pending_import,0)
		_pending_import = {}
		return
	var n := int(_pending_import.get("nodes",[]).size())
	import_mode_menu.clear()
	#带 %d 的那条要【先查表、后格式化】：反过来的话 %d 会被当成 key 的一部分查不到
	import_mode_menu.add_item(ExposeCheck_I18n.t("清空重建（先删掉图上全部节点，导入 %d 个）") % n,0)
	import_mode_menu.add_item(ExposeCheck_I18n.t("合并进现有图（按 key 去重）"),1)
	import_mode_menu.add_separator()
	import_mode_menu.add_item(ExposeCheck_I18n.t("取消"),2)
	import_mode_menu.position = PopupHelper.to_window_position(import_mode_menu,self,global_position + size * 0.5)
	import_mode_menu.popup()


func _on_import_mode_id_pressed(id:int) -> void:
	if id == 2:
		_pending_import = {}
		return
	apply_blueprint(_pending_import,id)
	_pending_import = {}


func _on_export_pressed() -> void:
	_ask_json_path(0)


func _on_save_selected_pressed() -> void:
	_ask_json_path(1)


func _on_import_pressed() -> void:
	_ask_json_path(2)


func _on_clear_all_pressed() -> void:
	clear_all_nodes()
#endregion


func _popup_it() -> void:
		_fd.popup_centered_ratio(editor_file_dialog_ratio)

func del_select_node()->void:
	var stay:Array[ExposeCheck_ScriptNode] = []
	for node in _current_node:
		if not is_instance_valid(node):
			continue
		if !node.selected:
			stay.append(node)
			continue
		var k := node.get_node_key()
		_node_by_key.erase(k)
		#节点没了，它牵涉的连线记录也一起清掉
		for i in range(_edges.size() - 1,-1,-1):
			if _edges[i]["from"] == k or _edges[i]["to"] == k:
				_edges.remove_at(i)
		node.free()
	_current_node = stay
	

func _on_popup_request(at_mouse_position: Vector2) -> void:
	float_menu.visible = true
	_mouse_in_ge_pos = at_mouse_position
	# 趁现在把图坐标算好存下来：PopupMenu 被点掉之后会 hide，hide 之后再读它的 position 不可靠
	_mouse_in_graph_area_pos = _screen_to_graph(get_global_mouse_position())
	#FloatMenu 是原生弹窗，position 要的是屏幕坐标；直接给画布坐标会差出整个编辑器窗口的偏移
	float_menu.position = PopupHelper.to_window_position(float_menu,self,get_global_mouse_position())


func _on_float_menu_id_pressed(id: int) -> void:
	match id:
		0: _popup_it()              # 新建节点（挑一个脚本）
		1: del_select_node()        # 删除选中节点
		2: _ask_json_path(0)        # 导出全部
		3: _ask_json_path(1)        # 保存选中
#endregion
