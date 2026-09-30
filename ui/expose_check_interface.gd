@tool
extends Control

##注释窗和右键菜单都是常驻实例（和 FloatMenu 一样写在场景里），
##只 show/hide 和换内容，不做频繁的创建销毁。
const DEFAULT_HINT := "无注释"

const PopupHelper = preload("res://addons/expose_check/ui/popup_helper.gd")

@onready var _graph_area = %GraphArea
@onready var _config_panel = %ConfigPanel
@onready var _hint_popup:PopupPanel = %HintPopup
@onready var _hint_label:Label = %HintLabel
@onready var _port_menu:PopupMenu = %PortMenu

##右键菜单当前作用的目标块和候选定义，避免用 bind 造出一堆无法断开的 Callable
var _menu_target:ExposeCheck_ContainerBlock = null
var _menu_defs:Array[ExposeCheck_PortInfo] = []


func _ready() -> void:
	#把界面上所有静态文案换成本地化文本：中文原文就是 key，所以 .tscn 一个字都不用改。
	#【只能在这里调一次】—— LineEdit 的 text 也算"用户数据"（端口含义输入框的初始值就
	#写在场景里），用户开始输入之后再 apply 会按"原文"把他的内容覆盖掉。
	ExposeCheck_I18n.apply(self)
	_hint_label.text = ExposeCheck_I18n.t(DEFAULT_HINT)
	_hint_popup.hide()
	_port_menu.id_pressed.connect(_on_port_menu_id_pressed)
	_graph_area.hint_requested.connect(_on_hint_requested)
	_graph_area.port_menu_requested.connect(_on_port_menu_requested)
	#设置里改了端口定义 → 让图上所有节点按新定义刷一遍（L0 刷新，不重建节点）
	_config_panel.port_definitions_changed.connect(_on_port_definitions_changed)
	#端口类型规则要先注册给 GraphEdit，拖拽时才会拦住不同类型
	_graph_area.refresh_valid_connection_types()


##左键点了某个 ExposeCheck_ContainerBlock：把常驻的注释窗挪到鼠标处再显示
func _on_hint_requested(hint_string:String,at_position:Vector2) -> void:
	var t := hint_string.strip_edges()
	_hint_label.text = t if not t.is_empty() else ExposeCheck_I18n.t(DEFAULT_HINT)
	_hint_popup.reset_size()                 # 按新内容重新算尺寸
	_hint_popup.position = PopupHelper.to_window_position(_hint_popup,self,at_position)
	_hint_popup.show()


##右键点了某个 ExposeCheck_ContainerBlock：复用同一个 PopupMenu，只换条目
func _on_port_menu_requested(block:ExposeCheck_ContainerBlock,at_position:Vector2) -> void:
	_menu_target = block
	_menu_defs = _config_panel.get_port_definitions()
	_port_menu.clear()
	#第 1 项永远是「默认」：块刚建出来就是它，也让人能把选过的块改回来。
	_port_menu.add_item(ExposeCheck_I18n.t("1: 默认（没有对应设置项）"),1)
	for i in _menu_defs.size():
		#菜单 id 直接用【端口类型】。号段：0 父类 / 1 默认 / 2 起是设置面板的定义，
		#设置面板第 i 行（界面上标 "i+1:"）对应端口类型 i+2。
		_port_menu.add_item("%d: %s / %s" % [i + 2,_menu_defs[i].left_mean,_menu_defs[i].right_mean],i + 2)
	if _menu_defs.is_empty():
		_port_menu.add_separator()
		_port_menu.add_item(ExposeCheck_I18n.t("（设置里还没有定义端口，只能先用默认）"),0)
		_port_menu.set_item_disabled(_port_menu.item_count - 1,true)
	_port_menu.position = PopupHelper.to_window_position(_port_menu,self,at_position)
	_port_menu.popup()


func _on_port_menu_id_pressed(id:int) -> void:
	#id 就是端口类型；块里存类型而不是 ExposeCheck_PortInfo 副本，设置改了才好重新套用
	if _menu_target == null:
		return
	if id == ExposeCheck_ScriptNode.DEFAULT_PORT_TYPE:
		#「默认」这个类型没有对应定义，直接清掉选择
		_menu_target.apply_port_info(null,ExposeCheck_ScriptNode.DEFAULT_PORT_TYPE)
		_menu_target = null
		return
	var idx := id - ExposeCheck_ScriptNode.PORT_TYPE_SETTINGS_BASE
	if idx < 0 or idx >= _menu_defs.size():
		return
	_menu_target.apply_port_info(_menu_defs[idx],id)
	_menu_target = null


##设置面板里的端口定义变了：合法端口类型范围跟着变，重新注册并刷新每个节点
func _on_port_definitions_changed() -> void:
	_graph_area.refresh_valid_connection_types()
	for c in _graph_area.get_children():
		if c is ExposeCheck_ScriptNode:
			c.refresh_port_settings()


##TopMenu 的「刷新所有节点」：只处理脏节点（脚本 md5 和节点记录不符的）
func _on_refresh_pressed() -> void:
	_graph_area.refresh_dirty_nodes()


##TopMenu 的「删除所有节点」
func _on_delete_all_node_pressed() -> void:
	_graph_area.clear_all_nodes()


#region 给 EditorPlugin 的会话保存 / 恢复
##整张图 + 端口定义打包成一份文档
func export_doc() -> Dictionary:
	return _graph_area.export_blueprint(false)


##恢复会话：直接清空重建，不弹「清空 / 合并」选单 ——
##编辑器刚起来时图本来就是空的，问一句纯属打扰。
func apply_doc(doc:Dictionary) -> void:
	_graph_area.apply_blueprint(doc,0)
#endregion
