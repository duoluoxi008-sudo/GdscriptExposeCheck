extends RefCounted

## 在 GDScript 源码上增删暴露标记、生成成员存根。
##
## 铁律：【只做行级插入 / 删除 / 注释】，绝不整文件重写 ——
## 否则用户的排版、空行、注释会被整片抹掉，那比不改还糟。
## 所有函数都收 Array/​PackedStringArray 并返回新的数组，读写文件是调用方的事。
##
## 标记语法直接用 script_analyzer 里那一套正则，不另起炉灶：
## 两处对「#expose 长什么样」的理解一旦不一致，就会静默地改错文件。
##
## 用 preload 引用，不加 @tool、不加 class_name。

const ScriptAnalyzer = preload("res://addons/expose_check/ui/script_analyzer.gd")

## 能生成代码存根的成员种类。用 ASCII id，对应 ExposeCheck_ScriptInfo.KIND_TABLE。
## 常量和枚举不行 —— 它们的值是凭空造不出来的，硬造只会写出错代码。
const GENERATABLE:Array[String] = ["func","static_func","ab_func","signal","var"]


## 种类的英文显示名。查 ExposeCheck_ScriptInfo.KIND_TABLE，没登记就原样返回 ——
## 不在这儿再抄一份表，抄了迟早和种类表漂移。
## 这些消息最终由 CLI 打印，而 CLI 固定英文，所以不走 i18n。
static func kind_en(kind:String) -> String:
	var k := ExposeCheck_ScriptInfo.kind_of(kind)
	return String(k.get("en",kind))


## 这个种类能不能生成存根
static func can_generate(kind:String) -> bool:
	return GENERATABLE.has(kind)


## 猜文件用什么缩进：取第一个「有缩进的代码行」前面的空白。猜不到就用 Tab（GDScript 官方风格）。
static func detect_indent(lines:PackedStringArray) -> String:
	for line in lines:
		if line.strip_edges().is_empty():
			continue
		var lead := _indent_of(line)
		if lead != "":
			return lead
	return "\t"


## 该往哪一行【之前】插东西：文件最后一个非空行的下一行。
static func class_body_end(lines:PackedStringArray) -> int:
	for i in range(lines.size() - 1,-1,-1):
		if not lines[i].strip_edges().is_empty():
			return i + 1
	return 0


## 某个声明行是不是已经被暴露了。
## 规则和 script_analyzer 保持一致：紧邻上方的标记优先于 region。
static func is_exposed(lines:PackedStringArray,decl_index:int) -> bool:
	if decl_index < 0 or decl_index >= lines.size():
		return false
	var re := ScriptAnalyzer._compile_regexes()
	#① 紧邻上方的标记（中间可以隔空行 / 注释 / 注解行）
	var i := decl_index - 1
	while i >= 0:
		var s:String = lines[i]
		if re["expose"].search(s):
			return true
		if re["unexpose"].search(s):
			return false
		var t := s.strip_edges()
		if t.is_empty() or t.begins_with("#") or t.begins_with("@"):
			i -= 1
			continue
		break
	#② 没有标记，就看它处在哪个 region 里
	var stack:Array[bool] = []
	for j in range(0,decl_index):
		var s2:String = lines[j]
		if re["region_expose"].search(s2):
			stack.push_back(true)
		elif re["region_unexpose"].search(s2):
			stack.push_back(false)
		elif re["endregion"].search(s2) and not stack.is_empty():
			stack.pop_back()
	return stack.back() if not stack.is_empty() else false


## 在某行之前插入若干行，返回新的数组。
static func insert_lines(lines:PackedStringArray,at:int,new_lines:PackedStringArray) -> PackedStringArray:
	var out := PackedStringArray()
	var pos:int = clampi(at,0,lines.size())
	for i in range(0,pos):
		out.append(lines[i])
	for l in new_lines:
		out.append(l)
	for i in range(pos,lines.size()):
		out.append(lines[i])
	return out


## 给某个声明补 #expose 标记。幂等：已经暴露就原样返回。
## 返回 { "lines": PackedStringArray, "changed": bool }
static func ensure_exposed(lines:PackedStringArray,decl_index:int) -> Dictionary:
	if is_exposed(lines,decl_index):
		return {"lines":lines,"changed":false}
	var indent := _indent_of(lines[decl_index])
	return {"lines":insert_lines(lines,decl_index,PackedStringArray([indent + "#expose"])),"changed":true}


## 去掉某个成员的暴露。三种情况分开处理 —— 光删 #expose 是不够的：
##   ① 紧邻上方有它自己的 #expose  → 删掉那一行
##   ② 它是靠 #region expose 暴露的 → 在它上方插一行 #unexpose 挡掉
##   ③ 本来就没暴露                → 什么都不做
## 返回 { "lines": PackedStringArray, "changed": bool, "message": String }
static func remove_expose(lines:PackedStringArray,decl_index:int) -> Dictionary:
	if decl_index < 0 or decl_index >= lines.size():
		return {"lines":lines,"changed":false,"message":"declaration line not found"}
	var re := ScriptAnalyzer._compile_regexes()
	#① 找它自己的标记（中间可以隔空行 / 注释 / 注解行）
	var i := decl_index - 1
	while i >= 0:
		var s:String = lines[i]
		if re["expose"].search(s):
			var out := lines.duplicate()
			out.remove_at(i)
			return {"lines":out,"changed":true,"message":"removed its own #expose marker"}
		if re["unexpose"].search(s):
			return {"lines":lines,"changed":false,"message":"it already has #unexpose"}
		var t := s.strip_edges()
		if t.is_empty() or t.begins_with("#") or t.begins_with("@"):
			i -= 1
			continue
		break
	#② 没有自己的标记，看看是不是靠 region 暴露的
	if is_exposed(lines,decl_index):
		var indent := _indent_of(lines[decl_index])
		return {"lines":insert_lines(lines,decl_index,PackedStringArray([indent + "#unexpose"])),"changed":true,"message":"it is exposed via #region expose; added #unexpose to block it"}
	return {"lines":lines,"changed":false,"message":"it was not exposed anyway"}


#region region 的增删
## 找包住某一行的【最内层】region。
## 返回 { "open": 开标记行号, "close": 关标记行号, "expose": bool }；没被包住返回 {}。
static func find_enclosing_region(lines:PackedStringArray,decl_index:int) -> Dictionary:
	var re := ScriptAnalyzer._compile_regexes()
	var stack:Array[Dictionary] = []
	#扫到 decl_index 之前为止：正好在它上面闭合的 region 不算包住它
	for j in range(0,mini(decl_index,lines.size())):
		var s:String = lines[j]
		if re["region_expose"].search(s):
			stack.append({"open":j,"expose":true})
		elif re["region_unexpose"].search(s):
			stack.append({"open":j,"expose":false})
		elif re["endregion"].search(s) and not stack.is_empty():
			stack.pop_back()
	if stack.is_empty():
		return {}
	var inner:Dictionary = stack[stack.size() - 1]
	#从开标记往下找它配对的那个 #endregion（按栈深度配对）
	var depth := 0
	for j in range(int(inner["open"]),lines.size()):
		if re["region_expose"].search(lines[j]) or re["region_unexpose"].search(lines[j]):
			depth += 1
		elif re["endregion"].search(lines[j]):
			depth -= 1
			if depth == 0:
				return {"open":inner["open"],"close":j,"expose":inner["expose"]}
	return {}


## 把一组成员（按名字）整段用 #region 包起来。
## 范围 = 【第一个成员的声明行】到【最后一个成员的块尾】——块尾用 _find_block_end 找，
## 不然函数体中间的 #endregion 会把函数劈成两半。
## 返回 { "lines":…, "changed":bool, "messages":Array[String] }
static func wrap_members_in_region(lines:PackedStringArray,names:Array,expose_it:bool,file_label:String = "") -> Dictionary:
	var info := ScriptAnalyzer.analyze_lines(lines,file_label)
	var first := -1
	var last := -1
	var missing:Array[String] = []
	for n in names:
		var at:int = _decl_line(info,StringName(String(n)))
		if at < 0:
			missing.append(String(n))
			continue
		if first < 0 or at < first:
			first = at
		var end := ScriptAnalyzer._find_block_end(lines,at + 1,lines.size(),_indent_of(lines[at]).length())
		#_find_block_end 会跳过空行，这里往回退到最后一个非空行，
		#免得 #endregion 前面挂一串空行
		while end - 1 > at and lines[end - 1].strip_edges().is_empty():
			end -= 1
		if end - 1 > last:
			last = end - 1
	var messages:Array[String] = []
	for m in missing:
		messages.append(m + ": not found in the script, ignored")
	if first < 0:
		return {"lines":lines,"changed":false,"messages":messages + ["no members found; nothing was done"]}
	var kind_text := "#region expose" if expose_it else "#region unexpose"
	#幂等：这一段已经正好被一对同类型的 region 包住就不动
	var enc := find_enclosing_region(lines,first)
	if not enc.is_empty() and int(enc["open"]) == first - 1 and int(enc["close"]) == last + 1 and bool(enc["expose"]) == expose_it:
		return {"lines":lines,"changed":false,"messages":messages + ["this range is already wrapped by a region of the same kind; left unchanged"]}
	var indent := _indent_of(lines[first])
	#先插后面那个，行号才不会因为前面插入而移位
	var out := insert_lines(lines,last + 1,PackedStringArray([indent + "#endregion"]))
	out = insert_lines(out,first,PackedStringArray([indent + kind_text]))
	#占位符顺序必须和中文版一致（%s 在前、两个 %d 在后）—— 换顺序就会串参数
	messages.append("wrapped with %s: lines %d..%d" % [kind_text,first + 1,last + 1])
	return {"lines":out,"changed":true,"messages":messages}


## 拆掉包住某个成员的那一对 region 标记。
## 【注意：语义会变】里面的成员失去 region 的庇护，不再暴露。
## 想保住暴露状态，拆完自己给它们逐个补 #expose（CLI 的 expose 命令能做）。
static func unwrap_region(lines:PackedStringArray,decl_index:int) -> Dictionary:
	var enc := find_enclosing_region(lines,decl_index)
	if enc.is_empty():
		return {"lines":lines,"changed":false,"messages":["this member is not inside any region"]}
	var out := lines.duplicate()
	out.remove_at(int(enc["close"]))     #先删后面那个，行号才不会移位
	out.remove_at(int(enc["open"]))
	#占位符顺序和中文版一致：%d 在前、%s 在后
	return {"lines":out,"changed":true,"messages":[
		"line %d: removed %s (members inside are no longer exposed)" % [
			int(enc["open"]) + 1,("#region expose" if bool(enc["expose"]) else "#region unexpose")]]}
#endregion


## 生成一个成员的存根（含文档注释和 #expose 标记）。
## member 里的 params / ret_type / prefix 是 script_analyzer 抓来的签名，原样抄回去 ——
## 不自己拼类型，免得抄错。
##
## indent = 这个成员自己的缩进层级（顶层成员就是 ""）
## step   = 一档缩进步长（Tab 还是四个空格），由 detect_indent() 给出。
## 【这两个不是一回事】：把步长当成层级用，会生成缩进的顶层成员，那是非法 GDScript。
static func make_stub(member:Dictionary,indent:String = "",step:String = "\t") -> PackedStringArray:
	var kind := String(member.get("kind",""))
	var name := String(member.get("name",""))
	var params := _params_text(member)
	var ret := String(member.get("ret_type",""))
	var pre := String(member.get("prefix",""))
	var out := PackedStringArray()
	for h in String(member.get("hint","")).split("\n"):
		if h.strip_edges() != "":
			out.append(indent + "## " + h.strip_edges())
	out.append(indent + "#expose")
	var ret_clause := (" -> " + ret) if ret != "" else ""
	match kind:
		"func", "static_func":
			out.append("%s%sfunc %s(%s)%s:" % [indent,pre,name,params,ret_clause])
			out.append(indent + step + "pass")
		"ab_func":
			out.append("%s%sfunc %s(%s)%s" % [indent,pre,name,params,ret_clause])
		"signal":
			out.append("%ssignal %s(%s)" % [indent,name,params])
		"var":
			out.append("%s%svar %s%s" % [indent,pre,name,(": " + ret) if ret != "" else ""])
	return out


## 把 [from, from+count) 整段注释掉。
## 缩进留在 "#" 前面（变成 "\t# func f():"），这样注释块和原文对得齐。
## 本来就是注释的行（## 文档、#expose 标记）不动 —— 再套一层会变成 "# #expose"，很难看。
static func comment_out(lines:PackedStringArray,from:int,count:int) -> PackedStringArray:
	var out := lines.duplicate()
	for i in range(maxi(from,0),mini(from + count,out.size())):
		var s := out[i]
		if s.strip_edges().begins_with("#"):
			continue
		var ind := _indent_of(s)
		out[i] = ind + "# " + s.substr(ind.length())
	return out


## 按蓝图给一个脚本补暴露标记 / 补代码存根。
##
## 策略【只增不减】：只往脚本里加东西，绝不删你手写的任何标记。
## 重名处理：蓝图要的成员脚本里已经有了 → 不重复声明，
##   把生成的存根整段注释掉、紧挨着已有成员（整个块之后）放，并记一条提醒。
##
## 返回 { "lines": PackedStringArray, "changed": bool, "messages": Array[String] }
static func apply_members(lines:PackedStringArray,members:Array,file_label:String = "") -> Dictionary:
	#从后往前处理：插入和注释都会让行号移位，倒着来就不必反复重算
	var info := ScriptAnalyzer.analyze_lines(lines,file_label)
	var todo:Array[Dictionary] = []
	var messages:Array[String] = []
	for m in members:
		if typeof(m) != TYPE_DICTIONARY:
			continue
		var kind := String(m.get("kind",""))
		var name := String(m.get("name",""))
		if name == "":
			continue
		if not can_generate(kind):
			#顺序和中文版一致：先名字、后种类
			messages.append("skipped %s (%s): its value cannot be invented - please add it by hand" % [name,kind_en(kind)])
			continue
		todo.append(m)
	todo.sort_custom(func(a,b): return _decl_line(info,StringName(String(a.get("name","")))) > _decl_line(info,StringName(String(b.get("name","")))))

	var out := lines.duplicate()
	#step 是「一档缩进步长」，不是成员自己的缩进层级。
	#存根一律插在类体末尾（顶层），所以成员缩进是 ""，函数体缩进用 step。
	var step := detect_indent(out)
	var changed := false
	for m in todo:
		var name := String(m.get("name",""))
		var kind := String(m.get("kind",""))
		var at := _decl_line(info,StringName(name))
		if at < 0:
			#脚本里没有 → 生成存根插到文件末尾
			var pos := class_body_end(out)
			out = insert_lines(out,pos,PackedStringArray([""]) + make_stub(m,"",step))
			changed = true
			#顺序和中文版一致：先种类、后名字
			messages.append("added a %s stub for %s (appended at the end of the class body)" % [kind_en(kind),name])
			continue
		#已经存在
		var decl_at := at
		var r := ensure_exposed(out,at)
		if r["changed"]:
			out = r["lines"]
			decl_at = at + 1         #插了一行标记，声明整体下移
			changed = true
			messages.append("%s already exists and was not exposed -> added #expose" % name)
		else:
			messages.append("%s already exists and is exposed -> left unchanged" % name)
		#把蓝图想要的写法注释掉放在它旁边当备注：不覆盖、不删除用户已有的那个（只增不减）。
		#必须从「声明行的下一行」开始找块尾 —— 从声明行本身开始会立刻返回它自己。
		var block_end := ScriptAnalyzer._find_block_end(out,decl_at + 1,out.size(),_indent_of(out[decl_at]).length())
		var note := PackedStringArray(["how the blueprint wrote %s (a member with the same name already exists above; kept for reference)" % name])
		#不要 #expose 那一行：注释块里一个 #expose 没有意义，只会变成 "# #expose"
		for l in make_stub(m,"",step):
			if l.strip_edges() != "#expose":
				note.append(l)
		out = insert_lines(out,block_end,comment_out(note,0,note.size()))
		changed = true
		messages.append("%s is a duplicate: the blueprint's stub was commented out, placed after the existing member" % name)
	return {"lines":out,"changed":changed,"messages":messages}


## 成员名 → 声明行号；没有返回 -1
static func _decl_line(info:ExposeCheck_ScriptInfo,name:StringName) -> int:
	if info == null:
		return -1
	return info.decl_lines.get(name,-1)


## 参数的显示文本
static func _params_text(member:Dictionary) -> String:
	var arr = member.get("params",[])
	if typeof(arr) != TYPE_ARRAY:
		return ""
	var parts := PackedStringArray()
	for p in arr:
		parts.append(String(p))
	return ", ".join(parts)


## 某一行的缩进
static func _indent_of(line:String) -> String:
	return line.substr(0,line.length() - line.strip_edges(true,false).length())


## 函数体的缩进步长：跟着文件的缩进风格走，别在空格项目里塞 Tab
static func _indent_step(indent:String) -> String:
	if indent != "" and not indent.contains("\t"):
		return indent
	return "\t"
