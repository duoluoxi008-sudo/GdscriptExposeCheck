@tool
extends PanelContainer

const BlueprintIO = preload("res://addons/expose_check/ui/blueprint_io.gd")

@export var graph_config_split:HSplitContainer
@export var input_line_scene:PackedScene

##端口定义（行号/文字/颜色）发生了变化，外面据此重新套用，不用重建节点
signal port_definitions_changed

##当前所有端口行。
##唯一数据源是 _port_container 的子节点，这里只是它的投影：
##增删一律由 child_entered_tree / child_exiting_tree 触发重建，不手工维护，因此不会留下悬空引用。
var current_port:Array[ExposeCheck_InputLine] = []

@onready var _port_container:VBoxContainer = _find_port_container()


func _ready() -> void:
	if _port_container == null:
		push_error(ExposeCheck_I18n.t("ConfigPanel: 找不到 PortConfigContainer"))
		return
	_port_container.child_entered_tree.connect(_on_ports_changed.unbind(1))
	_port_container.child_exiting_tree.connect(_on_ports_changed.unbind(1))
	_refresh_ports()


##“设置”按钮按下后弹出或者收起设置界面,若设置界面被拉开那么就关上，如果没有就打开
func _on_config_pressed() -> void:
	var arr:PackedInt32Array = [400]
	if graph_config_split.split_offsets[0]:
		arr = [0]
	graph_config_split.set_split_offsets(arr)


##添加最新的一个
func _on_add_new_item_pressed() -> void:
	if input_line_scene == null:
		push_warning(ExposeCheck_I18n.t("ConfigPanel: input_line_scene 未设置"))
		return
	var new_input:ExposeCheck_InputLine = input_line_scene.instantiate()
	_port_container.add_child(new_input)
	#按钮始终保持在最后
	var btn := _port_container.get_node_or_null(^"AddDelButton")
	if btn != null:
		_port_container.move_child(new_input, btn.get_index())
	#后续重建交给 child_entered_tree


##删除最后一个
func _on_delete_last_item_pressed() -> void:
	if current_port.is_empty():
		return
	current_port[-1].queue_free()
	#后续重建交给 child_exiting_tree


##子节点增删后重建 current_port 并重排序号
func _on_ports_changed() -> void:
	#child_exiting_tree 触发时节点还挂在树上，要等一帧再统计
	_refresh_ports.call_deferred()


func _refresh_ports() -> void:
	if _port_container == null:
		return
	current_port.clear()
	for child in _port_container.get_children():
		if child is ExposeCheck_InputLine:
			current_port.append(child)
			_watch_line(child)
	_renumber()
	port_definitions_changed.emit()


##监听某一行里文字和颜色的改动，改动就通知外面重新套用。
##is_connected 用的是方法 Callable，每次结果一样，所以不会重复连接。
func _watch_line(line:ExposeCheck_InputLine) -> void:
	if line.l_input != null and not line.l_input.text_changed.is_connected(_on_line_text_changed):
		line.l_input.text_changed.connect(_on_line_text_changed)
	if line.r_input != null and not line.r_input.text_changed.is_connected(_on_line_text_changed):
		line.r_input.text_changed.connect(_on_line_text_changed)
	if line.color_picker != null and not line.color_picker.color_changed.is_connected(_on_line_color_changed):
		line.color_picker.color_changed.connect(_on_line_color_changed)


func _on_line_text_changed(_new_text:String) -> void:
	port_definitions_changed.emit()


func _on_line_color_changed(_new_color:Color) -> void:
	port_definitions_changed.emit()


##序号是派生数据，统一在这里重排，避免增删后错位
func _renumber() -> void:
	for i in current_port.size():
		current_port[i].set_index_text("%d:" % (i + 1))


##优先用唯一名取，取不到时退回固定路径
func _find_port_container() -> VBoxContainer:
	var n := get_node_or_null(^"%PortConfigContainer")
	if n == null:
		n = get_node_or_null(^"VBoxContainer/PortConfig/PortConfigContainer")
	return n as VBoxContainer


##收集当前所有端口定义，供 ExposeCheck_ContainerBlock 的右键菜单使用
func get_port_definitions() -> Array[ExposeCheck_PortInfo]:
	var defs:Array[ExposeCheck_PortInfo] = []
	for line in current_port:
		defs.append(line.get_port_info())
	return defs


##整体替换端口定义。导入蓝图 / 恢复会话时用。
##这里必须同步跑一遍 _refresh_ports：正常路径是 deferred 的，
##不同步的话外面紧接着调 get_port_definitions() 拿到的还是旧表。
func set_port_definitions(defs:Array) -> void:
	if _port_container == null or input_line_scene == null:
		push_warning(ExposeCheck_I18n.t("ConfigPanel: 还没准备好，端口定义没能恢复"))
		return
	#先把已有的行全删掉（AddDelButton 留着）
	for line in current_port:
		if is_instance_valid(line):
			line.free()
	current_port.clear()
	var btn := _port_container.get_node_or_null(^"AddDelButton")
	for d in defs:
		if typeof(d) != TYPE_DICTIONARY:
			continue
		var line:ExposeCheck_InputLine = input_line_scene.instantiate()
		line.l_input.text = str(d.get("left",""))
		line.r_input.text = str(d.get("right",""))
		line.color_picker.color = BlueprintIO.hex_to_color(str(d.get("color","")),Color.WHITE)
		_port_container.add_child(line)
		if btn != null:
			_port_container.move_child(line,btn.get_index())
	_refresh_ports()
