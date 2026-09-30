extends RefCounted
class_name ExposeCheck_I18n

## 极简本地化：拿【中文原文】当 key，查到就换成目标语言，查不到原样返回。
##
## 为什么不用 Godot 标准的 TranslationServer + .translation：
## 实测（Godot 4.7.1）在编辑器里 add_translation() 注册成功、get_translation_object()
## 也拿得到那条消息，但 translate() 和 Control.atr() 都不用 —— 连编辑器自己的字符串
## （translate("Import")）也是原样返回，loaded_locales 初始就是 []。
## 也就是说编辑器 UI 的翻译不走 TranslationServer，那条路对编辑器插件不可靠。
##
## 所以这里自带一张表：
##   · 场景里的 text 一个字都不用改（中文原文就是 key），靠 apply() 统一替换
##   · 运行时动态生成的文本，在赋值那行调 t()
##   · 加一门语言 = 往 TABLE 里加一项
##
## 用 preload 引用，不加 @tool、不加 class_name（不再往全局命名空间塞东西）。
##
## 注意：这个模块只管【编辑器界面】。CLI 相关的模块（member_writer / blueprint_io /
## tools/expose_cli）固定输出英文，不经过这里 —— 它们常在 CI 里跑，输出不该随
## 编辑器语言变。

## 源语言。中文系一律走源语言，不用查表。
const SOURCE_LANG := "zh"


const TABLE := {
	"en": {
		# ── 顶部菜单 / 浮出菜单（场景）────────────────────────────
		"设置": "Settings",
		"导入": "Import",
		"导出": "Export",
		" 保存选中节点": " Save Selected",
		"刷新所有节点": "Refresh All Nodes",
		"删除选中节点": "Delete Selected",
		"删除所有节点": "Delete All Nodes",
		"新建节点": "New Node",
		"删除节点": "Delete Node",
		"保存选中": "Save Selected",

		# ── 调试按钮区 / 设置面板（场景）─────────────────────────
		"Debug按钮区->": "Debug area ->",
		"强制节点ShowPart按钮启用": "Force-enable ShowPart button",
		"设置Port含义": "Port meanings",
		" 输入": " Input",
		"输出": "Output",
		"添加最新一个": "Add row",
		"删除最后一个": "Remove last",

		# ── 节点 / 成员块（场景）────────────────────────────────
		"刷新": "Refresh",
		"当前状态": "State",
		" 父类:": " Parent:",
		"--父类ClassName--": "--ParentClass--",
		"--类型--": "--Kind--",
		"--左输入含义": "--left--",
		"右输入含义--": "--right--",
		"无注释": "No doc comment",

		# ── 成员种类：只用于【显示】──────────────────────────────
		# 数据键已经是 ASCII id 了（见 ExposeCheck_ScriptInfo.KIND_TABLE 的 "id"），
		# 这里的中文只是显示名；换语言换的就是这一列。
		"常量": "Constant",
		"枚举": "Enum",
		"信号": "Signal",
		"变量": "Variable",
		"函数": "Function",
		"抽象函数": "Abstract Func",
		"静态函数": "Static Func",

		# ── 端口类型菜单 / 导入选单（运行时）─────────────────────
		"1: 默认（没有对应设置项）": "1: Default (no settings row)",
		"（设置里还没有定义端口，只能先用默认）": "(No port definitions yet — Default only)",
		"蓝图": "Blueprint",
		"清空重建（先删掉图上全部节点，导入 %d 个）": "Clear and rebuild (wipes the graph, imports %d)",
		"合并进现有图（按 key 去重）": "Merge into current graph (dedupe by key)",
		"取消": "Cancel",

		# ── 编辑器里的警告与状态消息 ─────────────────────────────
		# 带 % 的条目【参数顺序必须和中文一致】—— 调用处是 t("...") % [args]，
		# 换了顺序就会串参数。翻译时只许改文字，不许调换占位符次序。
		"expose_check: 端口类型不匹配（%d -> %d），这条线不允许": "expose_check: port types differ (%d -> %d); connection rejected",
		"expose_check: 找不到脚本文件 ": "expose_check: script file not found: ",
		"expose_check: 找不到内部类 ": "expose_check: inner class not found: ",
		"expose_check: 继承链超过 %d 层，疑似循环，已停止": "expose_check: inheritance chain deeper than %d levels (likely a cycle); stopped",
		"expose_check: 继承接线失败 %s -> %s (err=%d)": "expose_check: failed to wire inheritance %s -> %s (err=%d)",
		"expose_check: 重新分析失败，节点未刷新 ": "expose_check: re-analysis failed; node not refreshed: ",
		"expose_check: 全局刷新，处理了 %d 个脏节点": "expose_check: refreshed %d dirty node(s)",
		"expose_check: 端口类型变了，这一行上 %d 条对不上的连线已断开": "expose_check: port type changed; dropped %d now-mismatched connection(s) on this row",
		"expose_check: 端口类型 0..%d 之间同类型可连": "expose_check: port types 0..%d may connect within the same type",
		"expose_check: 连线的一端已不存在（%s.%s -> %s.%s），这条线没有恢复": "expose_check: an endpoint no longer exists (%s.%s -> %s.%s); this link was not restored",
		"expose_check: 找不到设置面板，端口定义没有恢复": "expose_check: settings panel not found; port definitions were not restored",
		"expose_check: 已恢复 %d 条端口定义": "expose_check: restored %d port definition(s)",
		"expose_check: 蓝图里的节点建不出来，跳过 ": "expose_check: cannot build this node from the blueprint; skipped: ",
		"expose_check: 导入完成，%d 个节点 / %d 条线": "expose_check: import done — %d node(s) / %d link(s)",
		"expose_check: 有 %d 个节点的脚本在导出之后被改过，成员可能对不上": "expose_check: %d node(s) have scripts modified since export; members may not line up",
		"expose_check: 蓝图里的一条线端点不存在（%s -> %s），跳过": "expose_check: a blueprint link has a missing endpoint (%s -> %s); skipped",
		"expose_check: 已清空全部节点": "expose_check: cleared every node",
		"expose_check: 已写出 %d 个节点（选中范围=%s）到 %s": "expose_check: wrote %d node(s) (selected-only=%s) to %s",
		"expose_check: 成员 %s 已不在暴露列表里，它的端口定义被丢弃": "expose_check: member %s is no longer exposed; its port definition was dropped",
		"ConfigPanel: 找不到 PortConfigContainer": "ConfigPanel: PortConfigContainer not found",
		"ConfigPanel: input_line_scene 未设置": "ConfigPanel: input_line_scene is not set",
		"ConfigPanel: 还没准备好，端口定义没能恢复": "ConfigPanel: not ready; port definitions could not be restored",
		"expose_check: 会话已保存（%d 个节点 / %d 条端口定义）": "expose_check: session saved (%d node(s) / %d port definition(s))",
		"expose_check: 已恢复上次会话（%d 个节点）": "expose_check: restored the previous session (%d node(s))",
	},
}


## 当前该用哪门语言。中文系一律走源语言（不用查表），其它一律英文。
static func lang() -> String:
	var loc := TranslationServer.get_locale()
	if loc.begins_with("zh"):
		return SOURCE_LANG
	return "en" if TABLE.has("en") else SOURCE_LANG


## 查表。未命中就原样返回 —— 漏翻不会变成空白，只会露出中文，一眼看得出来。
static func t(s:String) -> String:
	var l := lang()
	if l == SOURCE_LANG or not TABLE.has(l):
		return s
	var table:Dictionary = TABLE[l]
	return table.get(s,s)


## 带参数的版本，省得到处写 t("...") % [...]
static func tf(s:String,args) -> String:
	return t(s) % args


## 把控件树上所有带 text 的节点换成本地化文本；原文存进 meta，便于重复调用。
##
## 【只应该在面板 _ready 时调一次】，因为 LineEdit 的 text 也是"用户数据"：
## 端口含义输入框的初始值就写在场景里（" 输入" / "输出"），换个语言要跟着变；
## 但用户一旦开始输入，再 apply 一次就会把他的内容按"原文"覆盖掉。
static func apply(root:Node) -> void:
	_apply_one(root)
	if root == null:
		return
	for c in root.find_children("*","",true,false):
		_apply_one(c)


static func _apply_one(n:Node) -> void:
	if n == null:
		return
	#PopupMenu（还有 Popup、Window 系）没有 text 属性，条目文本存在内部，
	#得单独走一遍 —— 不然右键菜单那些 "新建节点 / 删除节点 / 导出" 永远翻不到。
	if n is PopupMenu:
		_apply_menu(n)
		return
	if not ("text" in n):
		return
	var src:String
	if n.has_meta(&"i18n_src"):
		src = String(n.get_meta(&"i18n_src"))
	else:
		src = String(n.get("text"))
		n.set_meta(&"i18n_src",src)
	var now := t(src)
	if String(n.get("text")) != now:
		n.set("text",now)


## 翻 PopupMenu 的条目。
##
## 原文按条目下标记在 meta 里，这样重复调用是幂等的。
## 【条目数变了就整表重新记一次】—— 运行时会 clear() + add_item() 重建菜单
## （端口类型菜单、导入选单都是），那种情况下原来的原文清单已经对不上了。
static func _apply_menu(m:PopupMenu) -> void:
	var count := m.item_count
	var srcs:Array = m.get_meta(&"i18n_items",[]) if m.has_meta(&"i18n_items") else []
	if srcs.size() != count:
		srcs = []
		for i in count:
			var raw := m.get_item_text(i)
			srcs.append(raw)
			m.set_item_text(i,t(raw))
		m.set_meta(&"i18n_items",srcs)
		return
	for i in count:
		m.set_item_text(i,t(String(srcs[i])))
