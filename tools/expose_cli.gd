extends SceneTree

## ExposeCheck 命令行工具 —— 给 AI Skill / 脚本用，不需要打开编辑器。
##
## 用法（在项目根目录执行）：
##   godot --headless --path . --script res://addons/expose_check/tools/expose_cli.gd -- <命令> [参数...]
##
## 命令：
##   list     <脚本...>              列出脚本暴露给外界的成员
##   outline  <脚本|蓝图.json>       输出 markdown 大纲（给人和 AI 看）
##   expose   <脚本> <成员...>       给成员补 #expose 标记
##   unexpose <脚本> <成员...>       去掉成员的暴露（靠 region 暴露的会加 #unexpose）
##   apply    <蓝图.json> [脚本...]  按蓝图补标记 / 补代码存根（【只增不减】）
##   check    <蓝图.json> [脚本...]  只报告差异，绝不写文件
##
## 写文件的护栏：
##   ① 先备份成 <脚本>.bak
##   ② 只有 md5 和读进来时一致才写 —— 否则说明编辑器里刚改过，宁可放弃
##   ③ 只做行级插入 / 删除 / 注释，绝不整文件重写（否则排版全没了）
##
## 退出码：0 = 全部成功，1 = 有失败
##
## 分析逻辑全部复用 script_analyzer.gd —— 和编辑器插件同一份真相。
## 自己重写一套正则的话，「插件认为暴露的」和「这里认为暴露的」迟早会漂移。

const ScriptAnalyzer = preload("res://addons/expose_check/ui/script_analyzer.gd")
const BlueprintIO = preload("res://addons/expose_check/ui/blueprint_io.gd")
const MemberWriter = preload("res://addons/expose_check/ui/member_writer.gd")

## 成员种类表。直接用 ExposeCheck_ScriptInfo.KIND_TABLE —— 那是唯一真相，
## 编辑器 UI 也读它。这里不再抄一份（抄了迟早漂移）。
## 输出给用户看用 "en"（CLI 固定英文），写进蓝图用 "id"（ASCII 数据键）。
const KIND_TABLE:Array[Dictionary] = ExposeCheck_ScriptInfo.KIND_TABLE

var _total:int = 0
var _fail:int = 0


func _initialize() -> void:
	var argv := OS.get_cmdline_user_args()
	if argv.is_empty():
		_usage()
		quit(1)
		return
	var cmd:String = argv[0]
	var rest:Array = argv.slice(1)
	match cmd:
		"list":     _cmd_list(rest)
		"outline":  _cmd_outline(rest)
		"expose":   _cmd_marker(rest,true)
		"unexpose": _cmd_marker(rest,false)
		"apply":           _cmd_apply(rest,false)
		"check":           _cmd_apply(rest,true)
		"region-expose":   _cmd_region(rest,true)
		"region-unexpose": _cmd_region(rest,false)
		"region-remove":   _cmd_region_remove(rest)
		"blueprint":       _cmd_blueprint(rest)
		_:
			push_error("Unknown command: " + cmd)
			_usage()
			quit(1)
			return
	quit(1 if _fail > 0 else 0)


func _usage() -> void:
	print("""ExposeCheck CLI

  list     <script...>            list the members exposed to the outside
  outline  <script|bp.json>       print a markdown outline
  expose   <script> <member...>   add #expose markers to members
  unexpose <script> <member...>   remove exposure from members
  apply    <bp.json> [script...]  add markers / code stubs from a blueprint (add-only)
  check    <bp.json> [script...]  report differences only, never write files
  region-expose   <script> <member...>  wrap these members (first to last) in #region expose
  region-unexpose <script> <member...>  same as above, but with #region unexpose
  region-remove   <script> <member...>  strip the region markers around these members (changes exposure)
  blueprint       <script...> [-o file]  generate a blueprint from scripts (nodes and members only, no links)

Paths may be full res:// paths or relative to the project root.""")


#region list / outline
func _cmd_list(paths:Array) -> void:
	if paths.is_empty():
		_report_fail("list needs at least one script path")
		return
	for rel in paths:
		var path := _res(String(rel))
		var info = _analyze(path)
		if info == null:
			continue
		print("## " + path)
		if String(info.class_name_string) != "":
			print("   class_name: " + String(info.class_name_string))
		if String(info.father_script_path) != "":
			print("   extends: " + String(info.father_script_path))
		var n := 0
		for kind in KIND_TABLE:
			var items = info.get(kind["field"])
			if items == null:
				continue
			for it in items:
				n += 1
				print("   %-8s %s%s" % [kind["en"],String(it.expose_name),_sig_text(it,kind["id"])])
		print("   %d exposed members in total" % n)
		print("")


func _cmd_outline(paths:Array) -> void:
	if paths.is_empty():
		_report_fail("outline needs at least one path")
		return
	for rel in paths:
		var raw := String(rel)
		if raw.ends_with(".json"):
			_outline_blueprint(_res(raw))
		else:
			_outline_script(_res(raw))


func _outline_script(path:String) -> void:
	var info = _analyze(path)
	if info == null:
		return
	var title := String(info.class_name_string)
	if title == "":
		title = path.get_file().get_slice(".",0)
	print("# " + title)
	print("")
	print("- File: `" + path + "`")
	if String(info.father_script_path) != "":
		print("- Extends: `" + String(info.father_script_path) + "`")
	print("")
	for kind in KIND_TABLE:
		var items = info.get(kind["field"])
		if items == null or items.is_empty():
			continue
		print("## " + kind["en"])
		print("")
		for it in items:
			var hint := String(it.Dsharp_hint).strip_edges().replace("\n"," ")
			print("- `%s%s`%s" % [String(it.expose_name),_sig_text(it,kind["id"]),("  — " + hint) if hint != "" else ""])
		print("")
	for cname in info.expose_inner_class.keys():
		print("## Inner class " + String(cname))
		print("")
	print("")


func _outline_blueprint(path:String) -> void:
	var doc := BlueprintIO.load_from_file(path)
	if doc.is_empty():
		_report_fail("cannot read blueprint or unsupported version: " + path)
		return
	print("# Blueprint " + path.get_file())
	print("")
	var defs:Array = doc.get("port_definitions",[])
	if not defs.is_empty():
		print("## Port definitions")
		print("")
		print("Ranges: 0 = parent class only, 1 = default (no setting), 2 and up = the ones below (row i → port type i+2)")
		print("")
		for i in defs.size():
			var d:Dictionary = defs[i]
			print("- **%d** %s → %s  `%s`" % [i + 2,d.get("left",""),d.get("right",""),d.get("color","")])
		print("")
	var nodes:Array = doc.get("nodes",[])
	print("## Classes (%d)" % nodes.size())
	print("")
	for n in nodes:
		var e:Dictionary = n
		print("### " + String(e.get("key","")))
		print("")
		if String(e.get("inner_name","")) != "":
			print("- Inner class: " + String(e.get("inner_name","")))
		print("- md5: `%s`" % String(e.get("script_md5","")))
		var members:Array = e.get("members",[])
		for m in members:
			var mm:Dictionary = m
			var sig := _member_sig_text(mm,String(mm.get("kind","")))
			var hint := String(mm.get("hint","")).strip_edges().replace("\n"," ")
			print("  - `%s` %s%s%s" % [String(mm.get("kind","")),String(mm.get("name","")),sig,("  — " + hint) if hint != "" else ""])
		print("")
	var links:Array = doc.get("links",[])
	print("## Links (%d)" % links.size())
	print("")
	for l in links:
		var ll:Dictionary = l
		print("- %s → %s  [%s]" % [
			BlueprintIO.endpoint_label(ll.get("from",{})),
			BlueprintIO.endpoint_label(ll.get("to",{})),
			String(ll.get("semantic",""))])
	print("")
#endregion


#region expose / unexpose
func _cmd_marker(args:Array,expose_it:bool) -> void:
	if args.size() < 2:
		_report_fail((("expose" if expose_it else "unexpose")) + " needs: <script> <member...>")
		return
	var path := _res(String(args[0]))
	var names:Array = args.slice(1)
	_total += 1
	if not FileAccess.file_exists(path):
		_report_fail("script not found: " + path)
		return
	print((("Expose " if expose_it else "Unexpose ")) + path)
	_modify(path,func(lines:PackedStringArray) -> Dictionary:
		var out := lines
		var changed := false
		var messages:Array[String] = []
		for name in names:
			#每改一次都要重新分析：行号会移位
			var info := ScriptAnalyzer.analyze_lines(out,path)
			var at:int = info.decl_lines.get(StringName(String(name)),-1)
			if at < 0:
				messages.append(String(name) + ": member not found in script, skipped")
				continue
			var r := MemberWriter.ensure_exposed(out,at) if expose_it else MemberWriter.remove_expose(out,at)
			out = r["lines"]
			if r["changed"]:
				changed = true
			messages.append(String(name) + ": " + (("#expose added") if expose_it else String(r.get("message",""))))
		return {"lines":out,"changed":changed,"messages":messages})
#endregion


#region apply / check
func _cmd_apply(args:Array,dry_run:bool) -> void:
	if args.is_empty():
		_report_fail((("apply" if not dry_run else "check")) + " needs: <blueprint.json> [script...]")
		return
	var doc := BlueprintIO.load_from_file(_res(String(args[0])))
	if doc.is_empty():
		_report_fail("cannot read blueprint or unsupported version: " + String(args[0]))
		return
	#蓝图里的类 → 成员表
	var by_path:Dictionary[String,Array] = {}
	for n in doc.get("nodes",[]):
		if typeof(n) != TYPE_DICTIONARY:
			continue
		var path := String(n.get("script_path",""))
		if path == "":
			continue
		var members:Array = n.get("members",[])
		if not by_path.has(path):
			by_path[path] = []
		by_path[path].append_array(members)
	#要处理哪些脚本：显式给了就用给的，否则蓝图里全都要
	var targets:Array[String] = []
	if args.size() > 1:
		for a in args.slice(1):
			targets.append(_res(String(a)))
	else:
		for p in by_path.keys():
			targets.append(p)
	if targets.is_empty():
		_report_fail("no scripts to process")
		return
	for path in targets:
		_total += 1
		if not FileAccess.file_exists(path):
			_report_fail("script not found: " + path)
			continue
		var members:Array = by_path.get(path,[])
		print("[%s] %s" % [("check" if dry_run else "apply"),path])
		if members.is_empty():
			print("   blueprint has no member records for this script, skipped")
			continue
		if dry_run:
			_check_only(path,members)
		else:
			_modify(path,func(lines:PackedStringArray) -> Dictionary:
				return MemberWriter.apply_members(lines,members,path))


## 只报告差异，不写文件
func _check_only(path:String,members:Array) -> void:
	var info = _analyze(path)
	if info == null:
		return
	var missing:Array[String] = []
	var present:Array[String] = []
	var unexposed:Array[String] = []
	for m in members:
		if typeof(m) != TYPE_DICTIONARY:
			continue
		var name := String(m.get("name",""))
		var at:int = info.decl_lines.get(StringName(name),-1)
		if at < 0:
			missing.append(name)
			continue
		present.append(name)
		var lines := FileAccess.get_file_as_string(path).split("\n")
		if not MemberWriter.is_exposed(lines,at):
			unexposed.append(name)
	print("   blueprint wants %d members" % members.size())
	print("   %d already declared, %d of them not exposed" % [present.size(),unexposed.size()])
	print("   %d missing from the script%s" % [missing.size(),(": " + ", ".join(missing)) if not missing.is_empty() else ""])
	if not unexposed.is_empty():
		print("   need #expose: " + ", ".join(unexposed))
#endregion


#region region 增删 / 反向生成
## 把一组成员（从第一个到最后一个）整段包进 #region expose（或 unexpose）
func _cmd_region(args:Array,expose_it:bool) -> void:
	if args.size() < 2:
		_report_fail("region-expose / region-unexpose needs: <script> <member...>")
		return
	var path := _res(String(args[0]))
	var names:Array = args.slice(1)
	_total += 1
	if not FileAccess.file_exists(path):
		_report_fail("script not found: " + path)
		return
	print(("Wrap in #region expose: " if expose_it else "Wrap in #region unexpose: ") + path)
	_modify(path,func(lines:PackedStringArray) -> Dictionary:
		return MemberWriter.wrap_members_in_region(lines,names,expose_it,path))


## 拆掉包住这些成员的 region 标记。
## 一次只拆一个、拆完重新分析 —— 删两行之后所有行号都变了。
## 【注意】里面的成员会因此不再暴露，这是语义变化，不是纯格式改写。
func _cmd_region_remove(args:Array) -> void:
	if args.size() < 2:
		_report_fail("region-remove needs: <script> <member...>")
		return
	var path := _res(String(args[0]))
	var names:Array = args.slice(1)
	_total += 1
	if not FileAccess.file_exists(path):
		_report_fail("script not found: " + path)
		return
	print("Remove region: " + path)
	_modify(path,func(lines:PackedStringArray) -> Dictionary:
		var out := lines
		var changed := false
		var messages:Array[String] = []
		for n in names:
			var info := ScriptAnalyzer.analyze_lines(out,path)
			var at:int = info.decl_lines.get(StringName(String(n)),-1)
			if at < 0:
				messages.append(String(n) + ": not found in script, skipped")
				continue
			var r := MemberWriter.unwrap_region(out,at)
			out = r["lines"]
			if r["changed"]:
				changed = true
			for m in r["messages"]:
				messages.append(String(n) + ": " + String(m))
		return {"lines":out,"changed":changed,"messages":messages})


## 从脚本反向生成蓝图。
## 【只能生成节点和成员，生成不了连线】——连线是用户在图上表达的意图，
## 源码里没有任何对应物。位置、端口定义、端口类型同理，都是编辑器那边的事，
## 这里一律填默认值。
func _cmd_blueprint(args:Array) -> void:
	var paths:Array = []
	var out_path := ""
	var i := 0
	while i < args.size():
		var a := String(args[i])
		if a == "-o" and i + 1 < args.size():
			out_path = _res(String(args[i + 1]))
			i += 2
			continue
		paths.append(a)
		i += 1
	if paths.is_empty():
		_report_fail("blueprint needs at least one script path")
		return
	var doc := BlueprintIO.new_doc()
	for rel in paths:
		var path := _res(String(rel))
		_total += 1
		if not FileAccess.file_exists(path):
			_report_fail("script not found: " + path)
			continue
		var info = ScriptAnalyzer.analyze(path)
		if info == null:
			_report_fail("analysis failed: " + path)
			continue
		_blueprint_add_node(doc,path,info,path)
	if out_path == "":
		#没给 -o 就打标准输出，方便管道接给别的工具
		print(JSON.stringify(doc,"\t",true,false))
		return
	if BlueprintIO.save_to_file(out_path,doc) == OK:
		print("wrote %d nodes to %s" % [doc["nodes"].size(),out_path])


## 递归把一个 ScriptInfo（含它暴露的内部类）加成蓝图节点
func _blueprint_add_node(doc:Dictionary,path:String,info,key:String) -> void:
	var members:Array = []
	for kind in KIND_TABLE:
		var items = info.get(kind["field"])
		if items == null:
			continue
		for it in items:
			var params:Array = []
			for p in it.params:
				params.append(String(p))
			members.append({
				"kind": kind["id"],
				"name": String(it.expose_name),
				"hint": String(it.Dsharp_hint),
				"params": params,
				"ret_type": String(it.ret_type),
				"prefix": String(it.prefix),
			})
	doc["nodes"].append({
		"key": key,
		"script_path": String(info.file_name),
		"inner_name": String(info.inner_name),
		"class_name": String(info.class_name_string),
		"title": info.short_name,
		"script_md5": ScriptAnalyzer.file_md5(path),
		"position": [0.0,0.0],
		"size": [0.0,0.0],
		"port_types": {},
		"members": members,
	})
	#内部类也是类，递归下去
	for cname in info.expose_inner_class.keys():
		var inner = info.expose_inner_class[cname]
		_blueprint_add_node(doc,path,inner,"%s::%s" % [key,String(cname)])
#endregion


#region 读写与护栏
## 读 → 交给 mutator 改 → 带着护栏写回。
## mutator 收 PackedStringArray，返回 { "lines", "changed", "messages" }。
func _modify(path:String,mutator:Callable) -> void:
	var raw := FileAccess.get_file_as_string(path)
	if raw.is_empty():
		_report_fail("cannot read contents: " + path)
		return
	var md5_before := FileAccess.get_md5(path)
	var trailing_newline := raw.ends_with("\n")
	var lines := raw.split("\n")
	#文件以 \n 结尾时 split 会多出一个空串，去掉它，写回时再补回来
	if trailing_newline and lines.size() > 0:
		lines.remove_at(lines.size() - 1)
	var res:Dictionary = mutator.call(lines)
	for m in res.get("messages",[]):
		print("   · " + String(m))
	if not res.get("changed",false):
		print("   (no changes, file not written)")
		return
	#写之前再算一次 md5：读进来之后被改过就说明编辑器里动过了，宁可放弃
	if FileAccess.get_md5(path) != md5_before:
		_report_fail("file changed after it was read, giving up on write: " + path)
		return
	var bak := path + ".bak"
	DirAccess.copy_absolute(ProjectSettings.globalize_path(path),ProjectSettings.globalize_path(bak))
	var text := "\n".join(res["lines"])
	if trailing_newline:
		text += "\n"
	var f := FileAccess.open(path,FileAccess.WRITE)
	if f == null:
		_report_fail("cannot write " + path + " (error code " + str(FileAccess.get_open_error()) + ")")
		return
	f.store_string(text)
	f.close()
	print("   written; backup at " + bak)
#endregion


#region 小工具
## 相对路径 → res:// 全路径
func _res(p:String) -> String:
	if p.begins_with("res://") or p.begins_with("user://"):
		return p
	return "res://" + p.trim_prefix("./").replace("\\","/")


func _analyze(path:String):
	if not FileAccess.file_exists(path):
		_report_fail("script not found: " + path)
		return null
	return ScriptAnalyzer.analyze(path)


## 成员的签名显示文本。
## 只有函数和信号有参数表，变量/常量/枚举只在有显式类型时显示 ": 类型"。
func _sig_text(item,kind:String) -> String:
	var is_callable := kind == "func" or kind == "static_func" or kind == "ab_func" or kind == "signal"
	var s := ""
	if is_callable:
		s = "(" + ", ".join(item.params) + ")"
		if kind != "signal" and String(item.ret_type) != "":
			s += " -> " + String(item.ret_type)
	elif String(item.ret_type) != "":
		s = ": " + String(item.ret_type)
	var pre := String(item.prefix).strip_edges()
	if pre != "":
		s = "[" + pre + "] " + s
	return s


## 蓝图里那条成员记录的签名显示文本。逻辑和 _sig_text 一致 ——
## 变量/常量/枚举不该长括号（它们没有参数表）。
func _member_sig_text(m:Dictionary,kind:String) -> String:
	var is_callable := kind == "func" or kind == "static_func" or kind == "ab_func" or kind == "signal"
	var params:Array = m.get("params",[])
	var parts := PackedStringArray()
	for p in params:
		parts.append(String(p))
	var ret := String(m.get("ret_type",""))
	var s := ""
	if is_callable:
		s = "(" + ", ".join(parts) + ")"
		if kind != "signal" and ret != "":
			s += " -> " + ret
	elif ret != "":
		s = ": " + ret
	var pre := String(m.get("prefix","")).strip_edges()
	if pre != "":
		s = "[" + pre + "] " + s
	return s


func _report_fail(msg:String) -> void:
	_fail += 1
	printerr("Error: " + msg)
#endregion
