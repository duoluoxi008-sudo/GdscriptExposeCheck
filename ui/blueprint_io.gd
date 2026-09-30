extends RefCounted

##蓝图文件的读写。纯格式模块：不碰场景树、不改编辑器状态，方便单独测。
##用 preload 引用，不加 @tool、不加 class_name —— 和 script_analyzer 一个路子。
##
##格式约定：
##  - 节点 key 直接复用 ExposeCheck_ScriptNode.get_node_key()：
##      顶层类 = 脚本路径；内部类 = 脚本路径::内部类名（嵌套继续接 ::）
##  - 连线端点存【语义】：节点 key + 成员种类/名字 + 左右，**不存端口号**。
##    端口号会随成员增删整体漂移，存了就一定会错连。
##  - format_version 现在就写上，以后改格式好做兼容判断。

##版本历史：
##  v1 → v2：加了 port_definitions（端口定义整体入蓝图）
##  v2 → v3：成员的 "kind" 从中文显示名改成 ASCII id（"函数" → "func"），
##           port_types 的键（"种类\t成员名"）也跟着一起换
##版本不符直接拒绝读入 —— 宁可让人看见一条警告，也别按错的格式解析出一堆垃圾。
const FORMAT_VERSION := 3


##新建一份空文档
static func new_doc() -> Dictionary:
	return {
		"format_version": FORMAT_VERSION,
		"generator": "expose_check",
		"port_definitions": [],
		"nodes": [],
		"links": [],
		"view": {},
	}


##Color → "#rrggbbaa"。
##JSON 存不了 Color：stringify 会把它变成 "(0.2, 0.4, 0.6, 0.8)" 这种解不回来的字符串，
##所以统一走十六进制。注意 to_html() 不带 #，要自己加。
static func color_to_hex(c:Color) -> String:
	return "#" + c.to_html(true)


##"#rrggbbaa" → Color；解析不了就返回 fallback
static func hex_to_color(s:String,fallback:Color = Color.WHITE) -> Color:
	if s.is_empty():
		return fallback
	return Color.from_string(s,fallback)


##写盘。成功返回 OK。
static func save_to_file(path:String,doc:Dictionary) -> Error:
	var f := FileAccess.open(path,FileAccess.WRITE)
	if f == null:
		push_warning("expose_check: cannot write blueprint: " + path)
		return FileAccess.get_open_error()
	f.store_string(JSON.stringify(doc,"\t",true,false))
	f.close()
	return OK


##读盘。不存在 / 不是 JSON 对象 / 版本不认识 → 返回 {}
static func load_from_file(path:String) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_warning("expose_check: blueprint file not found: " + path)
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("expose_check: blueprint is not a valid JSON object: " + path)
		return {}
	var doc:Dictionary = parsed
	return _migrate(doc)


## 把老版本的文档升级到当前版本。
## 认不出来（版本号是 0 / 比当前还新 / 中间有跳不过去的版本）就返回 {}，
## 让调用方当成「读失败」——宁可报错，也别按错的格式解析出一堆垃圾。
static func _migrate(doc:Dictionary) -> Dictionary:
	var ver := int(doc.get("format_version",0))
	if ver == FORMAT_VERSION:
		return doc
	if ver > FORMAT_VERSION:
		push_warning("expose_check: blueprint version %d is newer than %d; cannot read" % [ver,FORMAT_VERSION])
		return {}
	var out := doc
	#逐版往上补，每轮只跨一个版本，方便以后插中间版本
	while int(out.get("format_version",0)) < FORMAT_VERSION:
		match int(out.get("format_version",0)):
			1:
				#v1 → v2：补 port_definitions 和每个节点的 members。
				#v1 压根没存这两样，所以只能补空。
				#端口定义是真的丢了；成员信息之后可以让 CLI 重新分析脚本拿回来。
				out["port_definitions"] = out.get("port_definitions",[])
				var nodes:Array = out.get("nodes",[])
				for n in nodes:
					if typeof(n) != TYPE_DICTIONARY:
						continue
					if not n.has("members"):
						n["members"] = []
					var members:Array = n["members"]
					for m in members:
						if typeof(m) != TYPE_DICTIONARY:
							continue
						if not m.has("params"):
							m["params"] = []
						if not m.has("ret_type"):
							m["ret_type"] = ""
						if not m.has("prefix"):
							m["prefix"] = ""
				out["format_version"] = 2
				push_warning("expose_check: blueprint migrated from v1 to v2 - v1 did not store port definitions, so that part is empty")
			2:
				#v2 → v3：成员的 kind 和 port_types 的键都从中文换成 ASCII id。
				#中文→id 的映射从种类表反推，不在本地另抄一份。
				var ch2id := {}
				for k in ExposeCheck_ScriptInfo.KIND_TABLE:
					ch2id[k["type"]] = k["id"]
				for n in out.get("nodes",[]):
					if typeof(n) != TYPE_DICTIONARY:
						continue
					var members:Array = n.get("members",[])
					for m in members:
						if typeof(m) != TYPE_DICTIONARY:
							continue
						m["kind"] = ch2id.get(String(m.get("kind","")),String(m.get("kind","")))
					#port_types 的键是 "种类\t成员名"，种类那一半也要换
					var pt:Dictionary = n.get("port_types",{})
					if not pt.is_empty():
						var newpt := {}
						for key in pt.keys():
							var parts := String(key).split("\t")
							if parts.size() == 2:
								newpt["%s\t%s" % [ch2id.get(parts[0],parts[0]),parts[1]]] = pt[key]
							else:
								newpt[key] = pt[key]
						n["port_types"] = newpt
				out["format_version"] = 3
				push_warning("expose_check: blueprint migrated from v2 to v3 - member kinds are now ASCII ids")
			_:
				push_warning("expose_check: unknown blueprint version %d; cannot migrate" % int(out.get("format_version",0)))
				return {}
	return out


##拼一个语义端点
static func make_endpoint(key:String,kind:String,member:String,slot:int,side:String) -> Dictionary:
	return {"key":key,"kind":kind,"name":member,"slot":slot,"side":side}


##取端点里的节点 key；不是字典就返回 ""
##注意用 str() 不要用 String()：String() 在 4.7 里只有无参形式，
##String(非字符串) 会报 "Nonexistent 'String' constructor" 并让整个函数返回默认值（空串）——
##不会崩，只会静默变空，很难查。
static func endpoint_key(ep) -> String:
	if typeof(ep) != TYPE_DICTIONARY:
		return ""
	return str(ep.get("key",""))


##取端点里成员的可读名字（给警告信息用）
static func endpoint_label(ep) -> String:
	if typeof(ep) != TYPE_DICTIONARY:
		return "?"
	var key := endpoint_key(ep)
	var member := str(ep.get("name",""))
	if member == "":
		#slot 从 JSON 读回来是 float，转成 int 再显示，免得出现 "[fixed row 1.0]"
		return "%s[fixed row %d]" % [key.get_file(),int(ep.get("slot",-1))]
	return "%s.%s" % [key.get_file(),member]
