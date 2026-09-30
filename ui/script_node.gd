@tool
extends GraphNode
class_name ExposeCheck_ScriptNode

##转发 ExposeCheck_ContainerBlock 的信号，供上层（ExposeCheckArea → 面板）消费
signal hint_requested(hint_string:String,at_position:Vector2)
signal port_menu_requested(block:ExposeCheck_ContainerBlock,at_position:Vector2)
##请求刷新自己。由 ExposeCheckArea 接手 —— 连线的快照/复原要看到整张图，节点自己做不到。
signal refresh_requested(node:ExposeCheck_ScriptNode)
##某个块的端口类型变了 → 请上层把这一行上已经不匹配的连线断掉。
##节点自己不删：断线还要同步维护 ExposeCheckArea 的 _edges 来源表。
signal port_type_changed(node:ExposeCheck_ScriptNode,row:int)

const ScriptAnalyzer = preload("res://addons/expose_check/ui/script_analyzer.gd")

##固定行数：0 = IDSolt，1 = FatherSolt。成员块从这一行之后开始。
##槽位号恒等于行号，所以不需要另外维护计数器——少一个会和实际结构脱节的变量。
const FIXED_ROW_COUNT := 2

##继承连线用的固定行：1 = FatherSolt。
##（slot 0 是 IDSolt，端口是关的，不用。）
const FATHER_ROW := 1

##端口类型号段（顺序不能动 —— 蓝图里存的就是这些数字）：
##   0    = 父类专属，只有 FatherSolt 那一行用，成员行不许用
##   1    = 默认创建时的类型。它是独立的一种，【不对应设置面板里的任何一行】
##   2 起 = 设置面板里的定义：类型 t ↔ _port_defs[t - PORT_TYPE_SETTINGS_BASE]
##          （面板上第 1 行标的是 "1:"，所以它对应端口类型 2 —— 别把这两个 1 搞混）
const PORT_TYPE_FATHER := 0
const DEFAULT_PORT_TYPE := 1
const PORT_TYPE_SETTINGS_BASE := 2

##没取到任何端口定义时用的中性色
const DEFAULT_PORT_COLOR := Color.WHITE

##成员块的种类表在 ExposeCheck_ScriptInfo.KIND_TABLE —— 那里是【唯一真相】，
##编辑器 UI / 蓝图 / CLI 全从它取。别再在本地抄一份，抄了迟早漂移。

var container_block_scene:PackedScene = preload("res://addons/expose_check/ui/ContainerBlock.tscn")
var script_info:ExposeCheck_ScriptInfo = null
##本节点对应脚本文件内容的 md5，用来判「脚本被改过没有」
var script_md5:String = ""
@export var class_name_slot:Label
@export var father_slot:Label
##脚本状态色：绿=和记录一致，红=盘上已经被改过
@export var state_color:ColorRect

##端口定义来源（「设置」面板）。留空就自动去面板场景里找 %ConfigPanel。
var settings_source:Node = null

##当前端口定义表的快照，下标就是「设置」里的行号
var _port_defs:Array[ExposeCheck_PortInfo] = []
##端口类型 id → 颜色。key 就是「设置」面板里端口定义的行号（0 起）。
var PortColor:Dictionary[int,Color] = {}


func _ready()->void:
	#ScriptNode 是运行时动态创建并挂进 GraphEdit 的，面板 _ready 那会儿它还不存在，
	#所以它自己场景里的静态文案（刷新 / 当前状态 / 父类:）必须在这儿翻一遍。
	#
	#这里能安全地整棵树 apply：入树那一刻，带"用户数据"的标签要么是 ASCII
	#（class_name_slot / father_slot / name_label，GDScript 标识符只能是 ASCII），
	#要么还是空的（左右端口含义标签要等 apply_port_info 才填），所以不会被误翻。
	ExposeCheck_I18n.apply(self)
	#动态实例化的节点 owner 是 null，% 用不了；而且块是在入树之前就建好的，
	#那时连父节点都没有，取不到设置。所以入树后再同步一次。
	refresh_port_settings()
	update_dirty_state()


func create_from_script_info(info:ExposeCheck_ScriptInfo)->void:
	script_info = info
	title = info.file_name if info.is_same_short_name else info.short_name
	class_name_slot.text = info.class_name_string
	father_slot.text = info.father_class_name_string
	script_md5 = ScriptAnalyzer.file_md5(get_script_path())
	rebuild_blocks()


##本节点对应的脚本路径（内部类沿用外层脚本路径）
func get_script_path()->String:
	return String(script_info.file_name) if script_info != null else ""


##本节点在图上的唯一 key。顶层 = 脚本路径；内部类 = 脚本路径::内部类名
func get_node_key()->String:
	return String(script_info.node_key) if script_info != null else ""


##父类在图上的唯一 key；"" 表示基类是原生类、不用建父节点
func get_father_node_key()->String:
	return String(script_info.father_node_key) if script_info != null else ""


##比对文件 md5 刷新状态色。绿=和记录一致，红=盘上改过了。
##路径不存在时不动颜色 —— 判断不了，乱标红反而误导。
func update_dirty_state()->void:
	if state_color == null:
		return
	var path := get_script_path()
	if path == "" or not ScriptAnalyzer.file_exists(path):
		return
	state_color.color = Color.GREEN if ScriptAnalyzer.file_md5(path) == script_md5 else Color.RED


func _on_refresh_pressed()->void:
	refresh_requested.emit(self)


##按成员身份找块；找不到返回 null。
##刷新时要靠它把端口定义和连线复原回来。
func find_block(kind:String,member:String)->ExposeCheck_ContainerBlock:
	for child in get_children():
		if child is ExposeCheck_ContainerBlock and child.member_kind == kind and child.member_name == member:
			return child
	return null


##按成员身份找槽位号（等于行号）；找不到返回 -1
func find_slot(kind:String,member:String)->int:
	var block := find_block(kind,member)
	return block.slot_index if block != null else -1


##槽位号（行号）→ connect_node / is_node_connected 要的【端口编号】。
##注意这两个不是一回事：端口只数「启用了端口的那几行」，是紧凑编号。
##ScriptNode.tscn 里 slot 0（IDSolt）端口是关的，所以 slot 1（FatherSolt）的端口编号是 0。
##自己数一遍，别依赖 get_output_port_count()：那个要等布局/绘制之后才有值。
func output_port_of_slot(slot:int)->int:
	#行不存在、或者这一行的输出端口是关的 → 这一行没有对应端口
	if slot < 0 or slot >= get_child_count() or not is_slot_enabled_right(slot):
		return -1
	var n := 0
	for i in range(slot):
		if is_slot_enabled_right(i):
			n += 1
	return n


func input_port_of_slot(slot:int)->int:
	if slot < 0 or slot >= get_child_count() or not is_slot_enabled_left(slot):
		return -1
	var n := 0
	for i in range(slot):
		if is_slot_enabled_left(i):
			n += 1
	return n


##端口编号 → 槽位号（和上面两个互为反函数）。越界返回 -1。
func output_slot_of_port(port:int)->int:
	var n := 0
	for i in get_child_count():
		if not is_slot_enabled_right(i):
			continue
		if n == port:
			return i
		n += 1
	return -1


func input_slot_of_port(port:int)->int:
	var n := 0
	for i in get_child_count():
		if not is_slot_enabled_left(i):
			continue
		if n == port:
			return i
		n += 1
	return -1


##槽位号（行号）→ 成员身份。固定行返回空的 kind/name。
func member_at_slot(slot:int)->Dictionary:
	if slot < FIXED_ROW_COUNT:
		return {"kind":"","name":""}
	var child := get_child(slot)
	if child is ExposeCheck_ContainerBlock:
		return {"kind":child.member_kind,"name":child.member_name}
	return {"kind":"","name":""}


##快照用户选过的端口定义：{ "种类\t成员名": 行号 }。
##刷新会把块全部重建，靠这个按成员身份套回去。
func snapshot_port_types()->Dictionary:
	var out := {}
	for child in get_children():
		if child is ExposeCheck_ContainerBlock and child.port_type_id >= 0:
			out["%s\t%s" % [child.member_kind,child.member_name]] = child.port_type_id
	return out


##按快照复原端口定义。成员已经没有了就丢掉，并留一条警告。
func restore_port_types(saved:Dictionary)->void:
	for k in saved.keys():
		var parts := String(k).split("\t")
		if parts.size() != 2:
			continue
		var block := find_block(parts[0],parts[1])
		if block == null:
			push_warning(ExposeCheck_I18n.t("expose_check: 成员 %s 已不在暴露列表里，它的端口定义被丢弃") % parts[1])
			continue
		#JSON 里的数字读回来是 float，显式转一下，别指望隐式转换
		apply_port_to_block(block,int(saved[k]))


##把某个端口类型套到块上（调用前先 refresh_port_settings()）
func apply_port_to_block(block:ExposeCheck_ContainerBlock,port_type:int)->void:
	if block == null:
		return
	block.apply_port_info(get_port_definition(port_type),port_type)


##从「设置」面板重新取端口定义，并把所有块按新表刷一遍。
##设置里改了颜色或含义之后调这个就能同步，不用重建节点。
func refresh_port_settings()->void:
	_port_defs.clear()
	PortColor.clear()
	var src := get_settings_source()
	if src != null:
		_port_defs = src.get_port_definitions()
		#PortColor 用【端口类型】当下标，不是设置里的行号：
		#设置面板第 i 行 → 端口类型 i + PORT_TYPE_SETTINGS_BASE
		for i in _port_defs.size():
			PortColor[i + PORT_TYPE_SETTINGS_BASE] = _port_defs[i].color
	_apply_port_settings()


##按当前定义表刷所有块：
##选过定义且定义还在的，用端口类型回表里查（文字和颜色一起更新）；
##没选过、或者选的那条已经被删了的，退回默认端口类型。
func _apply_port_settings()->void:
	var fallback := get_port_color(DEFAULT_PORT_TYPE)
	for child in get_children():
		if not (child is ExposeCheck_ContainerBlock) or child.slot_index < FIXED_ROW_COUNT:
			continue
		var info := get_port_definition(child.port_type_id)
		if info != null:
			child.apply_port_info(info,child.port_type_id)
			_set_slot_type_and_color(child.slot_index,child.port_type_id,info.color)
		else:
			child.apply_port_info(null,-1)
			_set_slot_type_and_color(child.slot_index,DEFAULT_PORT_TYPE,fallback)


##找「设置」面板：
##优先用外面注入的；没有的话走父节点（GraphArea，属于面板场景）的 owner 去取 %ConfigPanel，
##因为本节点是动态实例化的，自己的 owner 是 null。
func get_settings_source()->Node:
	if settings_source != null and is_instance_valid(settings_source):
		return settings_source
	var p := get_parent()
	if p != null and p.owner != null:
		return p.owner.get_node_or_null(^"%ConfigPanel")
	return null


##取某个端口类型的颜色；设置里没配过就返回中性色
func get_port_color(type_id:int)->Color:
	return PortColor.get(type_id,DEFAULT_PORT_COLOR)


##端口类型 → 端口定义。
##父类专属的 0 号和「默认」的 1 号都没有对应定义，一律返回 null。
func get_port_definition(port_type:int)->ExposeCheck_PortInfo:
	if port_type < PORT_TYPE_SETTINGS_BASE:
		return null
	var idx := port_type - PORT_TYPE_SETTINGS_BASE
	if idx >= _port_defs.size():
		return null
	return _port_defs[idx]


##设置里有几条端口定义
func get_port_definition_count()->int:
	return _port_defs.size()


##当前用得到的最大端口类型。
##就算设置里一条定义都没有，也至少有「默认」的 1 号。
func get_max_port_type()->int:
	return maxi(DEFAULT_PORT_TYPE,_port_defs.size() + PORT_TYPE_SETTINGS_BASE - 1)


##按 script_info 重建全部成员块。重复调用不会叠加，也不会留下悬空槽位。
##注意：重建会丢掉用户已选的端口定义（块是全新的）—— 刷新流程靠 snapshot/restore 兜住。
func rebuild_blocks()->void:
	_clear_blocks()
	if script_info == null:
		return
	var row := FIXED_ROW_COUNT
	for kind in ExposeCheck_ScriptInfo.KIND_TABLE:
		var items = script_info.get(kind["field"])
		if items == null:
			continue
		for item in items:
			_add_block(row,kind,item)
			row += 1


##倒着删：删掉一个，后面所有下标都会前移，正着删会漏掉一半
func _clear_blocks()->void:
	for row in range(get_child_count() - 1,FIXED_ROW_COUNT - 1,-1):
		clear_slot(row)
		var child := get_child(row)
		remove_child(child)
		child.queue_free()


## kind 是 KIND_TABLE 里的一条：id 进数据（member_kind），type 只用于显示
func _add_block(row:int,kind:Dictionary,item:ExposeCheck_ExposeNameAndDsharpHint)->void:
	var block:ExposeCheck_ContainerBlock = container_block_scene.instantiate() as ExposeCheck_ContainerBlock
	block.name = "Block_%s" % item.expose_name
	#左右端口含义先留空，等用户右键选了端口定义再由 apply_port_info 填
	block._build(kind["id"],kind["type"],String(item.expose_name),"","",item.Dsharp_hint)
	block.slot_index = row
	block.hint_requested.connect(hint_requested.emit)
	block.port_menu_requested.connect(port_menu_requested.emit)
	block.port_info_changed.connect(_on_block_port_info_changed)
	add_child(block)
	#必须先入树再设槽位，否则行号还不存在。
	#每个成员行左右端口都打开，颜色先用默认端口色。
	#注意此时节点自己可能还没入树、取不到设置，_ready() 里会再刷一次。
	var c:Color = get_port_color(DEFAULT_PORT_TYPE)
	set_slot(row,true,DEFAULT_PORT_TYPE,c,true,DEFAULT_PORT_TYPE,c)


##只改颜色，左右端口的开关和类型原样保留
func _set_slot_color(row:int,c:Color)->void:
	set_slot(row,\
		is_slot_enabled_left(row),get_slot_type_left(row),c,\
		is_slot_enabled_right(row),get_slot_type_right(row),c)


##端口类型和颜色一起换。
##类型一变，原来连到这个端口上的线就不再匹配了，但 GraphEdit 不会自动断开 —— 
##调用方要自己处理，别指望它。
func _set_slot_type_and_color(row:int,port_type:int,c:Color)->void:
	set_slot(row,\
		is_slot_enabled_left(row),port_type,c,\
		is_slot_enabled_right(row),port_type,c)


##用户在右键菜单里换了端口定义
func _on_block_port_info_changed(block:ExposeCheck_ContainerBlock,info:ExposeCheck_PortInfo)->void:
	var row:int = block.slot_index
	if row < FIXED_ROW_COUNT or row >= get_child_count():
		return
	var t:int = block.port_type_id if block.port_type_id > 0 else DEFAULT_PORT_TYPE
	_set_slot_type_and_color(row,t,info.color if info != null else get_port_color(t))
	#类型变了 → 这一行原来连的线可能已经对不上，交给上层去断
	port_type_changed.emit(self,row)
