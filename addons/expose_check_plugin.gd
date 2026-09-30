@tool
extends EditorPlugin

const CheckPanel = preload("res://addons/expose_check/ui/ExposeCheckPanel.tscn")
const BlueprintIO = preload("res://addons/expose_check/ui/blueprint_io.gd")

##会话快照：上次关掉编辑器时的整张图 + 端口定义，下次开编辑器自动读回来。
##放在插件自己的 auto_save/ 里，跟着项目走：
##   · 跨项目天然隔离（user:// 是按【项目名】分的，同名项目会撞在同一份状态上）
##   · 状态跟着仓库走，换机器 / 换协作者也带着
const SESSION_PATH := "res://addons/expose_check/auto_save/session.json"

##停靠面板的图标
const DOCK_ICON := "res://addons/expose_check/icon.svg"

var dock
var panel

func _enter_tree():
	dock = EditorDock.new()
	dock.title = "ExposeCheck"
	#这里故意用 load 而不是 preload：万一图标没导入成功，后果应该只是没图标，
	#而不是整个插件加载失败。
	var icon = load(DOCK_ICON)
	if icon != null:
		dock.dock_icon = icon
	dock.default_slot = EditorDock.DOCK_SLOT_RIGHT_UL
	panel = CheckPanel.instantiate()
	dock.add_child(panel)
	dock.default_slot = dock.DOCK_SLOT_BOTTOM
	add_dock(dock)
	#延后一帧恢复：面板的 _ready 和那些 @onready 得先跑完，否则取到的 GraphArea 还是空的
	_restore_session.call_deferred()

func _exit_tree():
	#先存再拆：拆完 dock 面板就没了，取不到图
	_save_session()
	remove_dock(dock)
	dock.queue_free()
	dock = null
	panel = null


##把当前图存成会话快照。
##任何一步不满足就安静跳过 —— 关编辑器的时候不该刷一堆错。
func _save_session() -> void:
	if panel == null or not is_instance_valid(panel) or not panel.has_method("export_doc"):
		return
	var doc:Dictionary = panel.export_doc()
	#auto_save/ 可能还不存在（头一次跑、或者被清理过），先建出来
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SESSION_PATH.get_base_dir()))
	if BlueprintIO.save_to_file(SESSION_PATH,doc) == OK:
		print(ExposeCheck_I18n.t("expose_check: 会话已保存（%d 个节点 / %d 条端口定义）") % [
			doc.get("nodes",[]).size(),doc.get("port_definitions",[]).size()])


func _restore_session() -> void:
	if panel == null or not is_instance_valid(panel) or not panel.has_method("apply_doc"):
		return
	if not FileAccess.file_exists(SESSION_PATH):
		return
	var doc := BlueprintIO.load_from_file(SESSION_PATH)
	if doc.is_empty():
		return
	panel.apply_doc(doc)
	print(ExposeCheck_I18n.t("expose_check: 已恢复上次会话（%d 个节点）") % doc.get("nodes",[]).size())
