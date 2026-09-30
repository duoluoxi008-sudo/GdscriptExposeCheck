@tool
extends PanelContainer
class_name ExposeCheck_ContainerBlock

##左键点击本块时发出。hint_string 可能为空字符串，由显示端兜底成默认文案。
##at_position 是建议的弹出位置（画布坐标），和 FloatMenu 的定位方式一致
signal hint_requested(hint_string:String,at_position:Vector2)
##右键点击本块，请求更换端口定义
signal port_menu_requested(block:ExposeCheck_ContainerBlock,at_position:Vector2)
##端口定义被更换后发出，ExposeCheck_ScriptNode 据此刷新槽位颜色
signal port_info_changed(block:ExposeCheck_ContainerBlock,info:ExposeCheck_PortInfo)

@export var type_label:Label
@export var name_label:Label
@export var left_port_label:Label
@export var right_port_label:Label

##本块对应的成员身份。刷新时要靠它把端口定义和连线复原回来，
##所以不能只从 type_label / name_label 的文本反推。
var member_kind:String = ""
var member_name:String = ""
##对应的 ## 文档注释，没有则为空字符串
var hint_string:String = ""
##本块选用的端口定义在「设置」里的行号（0 起）；-1 表示还没选。
##存行号而不是 ExposeCheck_PortInfo 副本，这样设置一改就能按行号重新套用。
var port_type_id:int = -1
##本块当前使用的端口定义，null 表示还没选
var port_info:ExposeCheck_PortInfo = null
##本块在 ExposeCheck_ScriptNode 上的槽位号，由 ExposeCheck_ScriptNode 建块时写入
var slot_index:int = -1


## kind_id 是 ASCII 数据键（func / var / …），kind_label 是中文显示名。
## 【两者必须分开传】：member_kind 存 id 供判断逻辑用，标签才走本地化显示。
func _build(kind_id:String,kind_label:String,name_string:String,l_port_string:String,r_port_string:String,hint:String = "")->void:
	member_kind = kind_id
	member_name = name_string
	type_label.text = ExposeCheck_I18n.t(kind_label)
	name_label.text = name_string
	left_port_label.text = l_port_string
	right_port_label.text = r_port_string
	hint_string = hint


##套用一份端口定义；type_id 是它在「设置」里的行号。传 null 表示清空。
func apply_port_info(info:ExposeCheck_PortInfo,type_id:int = -1)->void:
	port_type_id = type_id if info != null else -1
	port_info = info
	if info == null:
		left_port_label.text = ""
		right_port_label.text = ""
	else:
		left_port_label.text = info.left_mean
		right_port_label.text = info.right_mean
	port_info_changed.emit(self,info)


##左键只发信号、不 accept_event()：让点击继续冒泡给 GraphNode，
##否则按住本块就拖不动整个 ExposeCheck_ScriptNode 了。
##右键要 accept，免得 GraphEdit 又弹出它自己的右键菜单。
func _on_gui_input(event:InputEvent)->void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			hint_requested.emit(hint_string,get_global_mouse_position())
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			port_menu_requested.emit(self,get_global_mouse_position())
			accept_event()
