@tool
extends RefCounted

##弹窗定位工具。
##
##坑：Window.position 的口径取决于弹窗是「原生 OS 窗口」还是「内嵌子窗口」——
##  编辑器不开单窗口模式（interface/editor/single_window_mode = false，默认）时弹窗是原生的，
##    position 用【屏幕坐标】；
##  开了单窗口模式才是内嵌的，那时用【视口坐标】。
##而控件里拿到的鼠标/点击位置是【画布(=视口)坐标】，所以直接赋给 position 会差出
##整个编辑器窗口的屏幕偏移。窗口全屏时偏移是 (0,0)，所以这个问题平时看不出来。
##
##不要加 class_name：纯工具，用 preload 引用，免得往全局类表里塞东西。


##把画布坐标换算成某个弹窗的 Window.position 需要的口径。
##popup  : 要摆放的弹窗
##source : 坐标是从哪个节点量的（用来找它所在的 Window）
##canvas_pos : 画布坐标，例如 get_global_mouse_position()
static func to_window_position(popup:Window,source:Node,canvas_pos:Vector2) -> Vector2i:
	if popup == null or popup.is_embedded():
		return Vector2i(canvas_pos)
	var w:Window = source.get_window() if source != null else null
	if w == null:
		return Vector2i(canvas_pos)
	return Vector2i(canvas_pos) + w.position
