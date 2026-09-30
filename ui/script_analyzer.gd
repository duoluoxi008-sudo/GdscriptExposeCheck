extends RefCounted

##脚本静态分析器（只读）。
##
##设计约束：
##  - 只提供 static func，从不实例化 → 不需要 @tool，也不占场景树
##  - 只读：不写文件、不动编辑器状态、不改场景，只返回数据
##  - 用 preload 引用，不加 class_name，不往全局类表里塞东西
##
##正则每次分析都重新编译。
##不要改成「用静态缓存只编译一次」：面板在编辑器里长期存活，
##脚本热重载后缓存里的 RegEx 可能已经失效 → search() 空引用。


static func file_exists(path:String) -> bool:
	return FileAccess.file_exists(path)


static func file_md5(path:String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	return FileAccess.get_md5(path)


##直接读文本，不走 ResourceLoader（那会给缓存，盘上改了读不到新的）
static func read_source(path:String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open(path,FileAccess.READ)
	if f == null:
		return ""
	return f.get_as_text()


##解析一份脚本，返回填好的 ExposeCheck_ScriptInfo。
##注意：is_same_short_name 要看「图上已经有哪些节点」，那是调用方的事，这里不碰。
static func analyze(path:String) -> ExposeCheck_ScriptInfo:
	var info := ExposeCheck_ScriptInfo.new()
	info.file_name = path
	info.short_name = path.get_file().get_slice(".",0)
	var content := read_source(path)
	var re := _compile_regexes()
	#用 Script 接口拿父类，比正则可靠：extends 写成类名 / 路径 / 多级继承都能处理
	info.node_key = path
	info.father_script_path = resolve_parent_path(path)
	info.father_node_key = info.father_script_path
	var cn:RegExMatch = re["class_name"].search(content)
	if cn != null and cn.get_string(1) != "":
		info.class_name_string = cn.get_string(1)
	var fa:RegExMatch = re["extends"].search(content)
	if fa != null and fa.get_string(1) != "":
		info.father_class_name_string = fa.get_string(1)
	#extends 写成路径（extends "res://x.gd"）时正则抓不到名字，用父类脚本的文件名兜底
	if info.father_class_name_string == "" and info.father_script_path != "":
		info.father_class_name_string = info.father_script_path.get_file().get_slice(".",0)
	_collect_expose_names(content,info,re)
	return info


## 直接从行数组分析，不必先落盘再读一遍。member_writer / CLI 用这个。
## path_hint 只用来填 file_name / node_key / short_name，不会去读文件。
static func analyze_lines(lines:PackedStringArray,path_hint:String = "") -> ExposeCheck_ScriptInfo:
	var info := ExposeCheck_ScriptInfo.new()
	info.file_name = path_hint
	info.node_key = path_hint
	info.short_name = path_hint.get_file().get_slice(".",0) if path_hint != "" else ""
	_scan_lines(lines,0,-1,info,_compile_regexes())
	return info


##父类的脚本路径。脚本不存在 / 读不出来 / 基类是原生类 → 返回 ""
static func resolve_parent_path(path:String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var scr = ResourceLoader.load(path,"Script")
	if scr == null:
		return ""
	var base = scr.get_base_script()
	if base == null:
		return ""
	return base.resource_path


##全局类名 → 脚本路径；不是全局类（原生类 / 找不到）返回 ""
static func _global_class_path(class_name_str:String) -> String:
	for c in ProjectSettings.get_global_class_list():
		if String(c["class"]) == class_name_str:
			return String(c["path"])
	return ""


#region 正则表
## 标记必须独占一行，且 # 后面紧跟 expose / unexpose，
## 所以 "#region expose"、"#endregion expose"、代码里的 "#expose" 都不会被当成标记
static func _compile_regexes() -> Dictionary:
	return {
		"expose":          RegEx.create_from_string(r"^[ \t]*(?:#[eE][xX][pP][oO][sS][eE])+[ \t]*$"),
		"unexpose":        RegEx.create_from_string(r"^[ \t]*(?:#[uU][nN][eE][xX][pP][oO][sS][eE])+[ \t]*$"),
		"region_expose":   RegEx.create_from_string(r"^[ \t]*#[rR][eE][gG][iI][oO][nN][ \t]+[eE][xX][pP][oO][sS][eE]+[ \t]*$"),
		"region_unexpose": RegEx.create_from_string(r"^[ \t]*#[rR][eE][gG][iI][oO][nN][ \t]+[uU][nN][eE][xX][pP][oO][sS][eE]+[ \t]*$"),
		"endregion":       RegEx.create_from_string(r"^[ \t]*#[eE][nN][dD][rR][eE][gG][iI][oO][nN]\b"),
		"doc":             RegEx.create_from_string(r"^[ \t]*##"),
		"var":             RegEx.create_from_string(r'^[ \t]*(?:@[A-Za-z_]\w*(?:\((?:[^()"]|"(?:\\.|[^"\\])*")*\))?[ \t]+)*(?:static[ \t]+)?var[ \t]+([A-Za-z_]\w*)'),
		#变量的显式类型：var hp: int = 100 → "int"；var hp := 100 匹配不到（推导类型没法从一个名字还原）
		"var_type":        RegEx.create_from_string(r'^[ \t]*(?:@[A-Za-z_]\w*(?:\([^()]*\))?[ \t]+)*(?:static[ \t]+)?var[ \t]+[A-Za-z_]\w*[ \t]*:[ \t]*([A-Za-z_]\w*(?:\[[^\]]*\])?(?:\.[A-Za-z_]\w*)*)'),
		"func":            RegEx.create_from_string(r'^[ \t]*(?:@[A-Za-z_]\w*(?:\((?:[^()"]|"(?:\\.|[^"\\])*")*\))?[ \t]+)*(?:static[ \t]+)?func[ \t]+([A-Za-z_]\w*)[ \t]*\('),
		"signal":          RegEx.create_from_string(r"^[ \t]*(?:@[A-Za-z_]\w*(?:\([^()]*\))?[ \t]+)*signal[ \t]+([A-Za-z_]\w*)"),
		#内部类声明：class Inner: / class Inner extends Base: / @abstract class Inner:
		#class 后面必须紧跟空白，所以文件级的 class_name Foo 不会被误判
		"class":           RegEx.create_from_string(r'^[ \t]*(?:@[A-Za-z_]\w*(?:\([^()]*\))?[ \t]+)*class[ \t]+([A-Za-z_]\w*)(?:[ \t]+extends[ \t]+([A-Za-z_]\w*))?[ \t]*:'),
		#const 也会消耗 #expose 标记（不然标记会漏给下一个声明）
		"const":           RegEx.create_from_string(r'^[ \t]*(?:@[A-Za-z_]\w*(?:\([^()]*\))?[ \t]+)*const[ \t]+([A-Za-z_]\w*)'),
		#enum E{} / enum E {A,B} / enum E:（多行）；匿名 enum {A,B} 的名字组为空，整条跳过
		"enum":            RegEx.create_from_string(r'^[ \t]*(?:@[A-Za-z_]\w*(?:\([^()]*\))?[ \t]+)*enum(?:[ \t]+([A-Za-z_]\w*))?[ \t]*(\{|:)'),
		#static 只在「正则匹配到的那段文本」里找，注解字符串里的 "static func" 不会误判
		"static_func":     RegEx.create_from_string(r'(?:^|[^A-Za-z0-9_])static[ \t]+func[ \t]'),
		#@abstract 可能独占一行写在声明的上一行，所以要单独记注解
		"abstract":        RegEx.create_from_string(r'@abstract\b'),
		"class_name":      RegEx.create_from_string(r"class_name\s+([A-Za-z_]\w*)"),
		"extends":         RegEx.create_from_string(r"extends\s+([A-Za-z_]\w*)"),
	}


## 逐行扫描标记和声明，把标记状态套到声明上，结果写进 script_info。
## 规则：
##   #expose / #unexpose 管紧跟着它的那一个声明（中间可以隔空行、注释、注解）
##   #region expose / #region unexpose 管整个区域，直到配对的 #endregion
##   region 用栈配对：每个 #endregion 关掉最近打开的那个（和 if/else 一样），
##   所以嵌套时内层优先，碰到内层的 #endregion 就自动回到外层的状态
##   标记优先于 region：在内层 #region unexpose 里写一行 #expose 依然会被暴露
##   class 内部类：类体整段跳过，成员只进内部类自己的 ExposeCheck_ScriptInfo，绝不会进主类的数组；
##   被暴露的内部类再递归解析它的类体（递归用独立状态，不继承外层的 region / 标记）
static func _collect_expose_names(content:String,script_info:ExposeCheck_ScriptInfo,re:Dictionary) -> void:
	_scan_lines(content.split("\n"),0,-1,script_info,re)


## 扫描 lines[from, to)（to < 0 表示扫到结尾）。内部类递归调用时，传的就是它类体的行区间。
static func _scan_lines(lines:PackedStringArray,from:int,to:int,script_info:ExposeCheck_ScriptInfo,re:Dictionary) -> void:
	if to < 0 or to > lines.size():
		to = lines.size()
	var region_stack:Array[bool] = []          # true = #region expose，false = #region unexpose
	var pending_marker:int = -1                # -1 = 没有标记，0 = #unexpose，1 = #expose
	var pending_hint:PackedStringArray = PackedStringArray()
	var pending_annotations:PackedStringArray = PackedStringArray()   # 声明上方独占一行的注解（@abstract 可能在上一行）
	var in_multiline_string:bool = false
	var func_body_indent:int = -1              # >= 0 表示当前在函数体内，缩进回到 <= 它时函数结束
	var skip_until:int = from                  # 内部类体整段跳过，主类不许看里面的成员
	for index in range(from,to):
		if index < skip_until:
			continue
		var line:String = lines[index].trim_suffix("\r")
		# """ 多行字符串里面的内容不是代码
		if line.count('"""') % 2 == 1:
			in_multiline_string = not in_multiline_string
			continue
		if in_multiline_string:
			continue
		var stripped:String = line.strip_edges()
		var indent:int = line.length() - line.strip_edges(true,false).length()
		if func_body_indent != -1 and not stripped.is_empty() and indent <= func_body_indent:
			func_body_indent = -1
		if func_body_indent != -1:
			continue                            # 函数体内的语句不可能是成员声明
		if re["region_expose"].search(line):
			region_stack.push_back(true)
			continue
		if re["region_unexpose"].search(line):
			region_stack.push_back(false)
			continue
		if re["endregion"].search(line):
			if not region_stack.is_empty():
				region_stack.pop_back()
			continue
		#这里不清 pending_hint：## 写在标记上面还是下面都算这个声明的文档。
		#pending_hint 在每次消费完声明后都会清空，所以不会串到下一个声明。
		if re["unexpose"].search(line):
			pending_marker = 0
			continue
		if re["expose"].search(line):
			pending_marker = 1
			continue
		if re["doc"].search(line):
			pending_hint.append(stripped.trim_prefix("##").strip_edges())
			continue
		if stripped.is_empty() or stripped.begins_with("#"):
			continue
		var decl:RegExMatch = re["class"].search(line)
		var kind:int = ExposeCheck_ScriptInfo.Type.InClass
		if decl == null:
			decl = re["func"].search(line)
			kind = ExposeCheck_ScriptInfo.Type.Func
		if decl == null:
			decl = re["signal"].search(line)
			kind = ExposeCheck_ScriptInfo.Type.Signal
		if decl == null:
			decl = re["const"].search(line)
			kind = ExposeCheck_ScriptInfo.Type.Const
		if decl == null:
			decl = re["enum"].search(line)
			kind = ExposeCheck_ScriptInfo.Type.Enum
		if decl == null:
			decl = re["var"].search(line)
			kind = ExposeCheck_ScriptInfo.Type.Var
		if decl == null:
			if stripped.begins_with("@"):
				pending_annotations.append(stripped)    # 注解独占一行：记下来，@abstract 要认上一行
			else:
				pending_hint.clear()            # 只有注解行可以夹在 ## 和声明之间
				pending_annotations.clear()
			continue
		var expose_name:StringName = decl.get_string(1)
		#所有声明都记行号（不只是暴露的）：生成代码存根时要靠它判断成员是否已存在、往哪儿插
		if expose_name != &"":
			script_info.decl_lines[expose_name] = index
		# 函数再按修饰符细分：@abstract > static > 普通
		if kind == ExposeCheck_ScriptInfo.Type.Func:
			var decl_head:String = decl.get_string(0)   # 行首到 "(" 为止，已排除注解字符串里的内容
			var is_abstract:bool = re["abstract"].search(decl_head) != null
			if not is_abstract:
				for annotation in pending_annotations:
					if re["abstract"].search(annotation):
						is_abstract = true
						break
			if is_abstract:
				kind = ExposeCheck_ScriptInfo.Type.AbF
			elif re["static_func"].search(decl_head):
				kind = ExposeCheck_ScriptInfo.Type.StaticF
		elif kind == ExposeCheck_ScriptInfo.Type.Enum and expose_name == &"":
			# 匿名 enum（enum {A, B}）拿不到名字：整条跳过，但标记和注解要吃掉
			pending_marker = -1
			pending_hint.clear()
			pending_annotations.clear()
			continue
		var exposed:bool = false
		if pending_marker != -1:
			exposed = pending_marker == 1
		elif not region_stack.is_empty():
			exposed = region_stack.back()
		if kind == ExposeCheck_ScriptInfo.Type.InClass:
			# 内部类：先圈出类体让主类整段跳过，再（被暴露时）递归解析到它自己的 ExposeCheck_ScriptInfo 里
			var body_end:int = _find_block_end(lines,index + 1,to,indent)
			skip_until = body_end
			if exposed and expose_name != &"":
				var inner_hint:String = "\n".join(pending_hint)
				var inner_info:ExposeCheck_ScriptInfo = _add_expose(script_info,expose_name,inner_hint,kind)
				if inner_info != null:
					#内部类写了 extends 就以它为准；没写就用 add_new_expose_name 里默认的「外类」
					var inner_father:String = decl.get_string(2)
					if inner_father != "":
						inner_info.father_class_name_string = inner_father
						var fp := _global_class_path(inner_father)
						inner_info.father_script_path = fp
						inner_info.father_node_key = fp     #解析不到（原生类 / 不是全局类）就是空 → 不建父节点
					_scan_lines(lines,index + 1,body_end,inner_info,re)
			pending_marker = -1
			pending_hint.clear()
			pending_annotations.clear()
			continue
		if exposed and expose_name != &"":
			var hint:String = "\n".join(pending_hint)
			_add_expose(script_info,expose_name,hint,kind)
			#把签名补到刚加进去的那一条上 —— 生成代码存根要用
			var item = _last_added(script_info,kind)
			if item != null and item.expose_name == expose_name:
				_fill_item(item,kind,lines,index,decl,re,pending_annotations)
		if kind == ExposeCheck_ScriptInfo.Type.Func or kind == ExposeCheck_ScriptInfo.Type.AbF or kind == ExposeCheck_ScriptInfo.Type.StaticF:
			func_body_indent = indent
		pending_marker = -1
		pending_hint.clear()
		pending_annotations.clear()


## 从 start 往后找「第一个非空、且缩进 <= block_indent 的行」，返回它的下标（找不到就返回 to）。
## 用来圈出内部类的类体；途中会跳过 """ 多行字符串。
static func _find_block_end(lines:PackedStringArray,start:int,to:int,block_indent:int) -> int:
	var in_multiline_string:bool = false
	for index in range(start,to):
		var line:String = lines[index].trim_suffix("\r")
		if line.count('"""') % 2 == 1:
			in_multiline_string = not in_multiline_string
			continue
		if in_multiline_string:
			continue
		var stripped:String = line.strip_edges()
		if stripped.is_empty():
			continue
		if line.length() - line.strip_edges(true,false).length() <= block_indent:
			return index
	return to


## 按 type 分派到 add_new_expose_name；只有内部类会返回新建的 ExposeCheck_ScriptInfo（其余返回 null）。
static func _add_expose(script_info:ExposeCheck_ScriptInfo,expose_name:StringName,hint:String,kind:int) -> ExposeCheck_ScriptInfo:
	match kind:
		ExposeCheck_ScriptInfo.Type.Func:
			script_info.add_new_expose_name(expose_name,hint,ExposeCheck_ScriptInfo.Type.Func)
		ExposeCheck_ScriptInfo.Type.AbF:
			script_info.add_new_expose_name(expose_name,hint,ExposeCheck_ScriptInfo.Type.AbF)
		ExposeCheck_ScriptInfo.Type.StaticF:
			script_info.add_new_expose_name(expose_name,hint,ExposeCheck_ScriptInfo.Type.StaticF)
		ExposeCheck_ScriptInfo.Type.Signal:
			script_info.add_new_expose_name(expose_name,hint,ExposeCheck_ScriptInfo.Type.Signal)
		ExposeCheck_ScriptInfo.Type.Const:
			script_info.add_new_expose_name(expose_name,hint,ExposeCheck_ScriptInfo.Type.Const)
		ExposeCheck_ScriptInfo.Type.Enum:
			script_info.add_new_expose_name(expose_name,hint,ExposeCheck_ScriptInfo.Type.Enum)
		ExposeCheck_ScriptInfo.Type.InClass:
			return script_info.add_new_expose_name(expose_name,hint,ExposeCheck_ScriptInfo.Type.InClass)
		_:
			script_info.add_new_expose_name(expose_name,hint,ExposeCheck_ScriptInfo.Type.Var)
	return null


#region 签名抓取（生成代码存根要用）
## 种类 → ExposeCheck_ScriptInfo 里对应的数组字段名；内部类没有条目，返回 ""
static func _field_of(kind:int) -> String:
	match kind:
		ExposeCheck_ScriptInfo.Type.Func:    return "expose_func_name_arr"
		ExposeCheck_ScriptInfo.Type.AbF:     return "expose_ab_func_name_arr"
		ExposeCheck_ScriptInfo.Type.StaticF: return "expose_st_func_name_arr"
		ExposeCheck_ScriptInfo.Type.Signal:  return "expose_signal_name_arr"
		ExposeCheck_ScriptInfo.Type.Const:   return "expose_const_name_arr"
		ExposeCheck_ScriptInfo.Type.Enum:    return "expose_enum_name_arr"
		ExposeCheck_ScriptInfo.Type.Var:     return "expose_var_name_arr"
	return ""


## 声明关键字（用来从匹配文本里切出注解前缀）
static func _keyword_of(kind:int) -> String:
	match kind:
		ExposeCheck_ScriptInfo.Type.Func, ExposeCheck_ScriptInfo.Type.AbF, ExposeCheck_ScriptInfo.Type.StaticF: return "func"
		ExposeCheck_ScriptInfo.Type.Signal: return "signal"
		ExposeCheck_ScriptInfo.Type.Var:    return "var"
		ExposeCheck_ScriptInfo.Type.Const:  return "const"
		ExposeCheck_ScriptInfo.Type.Enum:   return "enum"
	return ""


## 取某个种类数组里最后加进去的那一条。
## add_new_expose_name 只往数组尾部 append，所以刚加的那条一定是最后一条。
static func _last_added(script_info:ExposeCheck_ScriptInfo,kind:int):
	var field := _field_of(kind)
	if field == "":
		return null
	var arr = script_info.get(field)
	if arr == null or arr.size() == 0:
		return null
	return arr[arr.size() - 1]


## 从匹配文本里切出关键字之前的注解和修饰符，例如 "@export var hp" → "@export "
static func _prefix_of(head:String,kw:String) -> String:
	var at := head.find(kw)
	if at <= 0:
		return ""
	var pre := head.substr(0,at).strip_edges()
	return pre + " " if pre != "" else ""


## 把签名填进成员条目。
## 函数和信号都要抓参数（信号也能跨行写参数表），只有函数有返回类型。
static func _fill_item(item,kind:int,lines:PackedStringArray,index:int,decl:RegExMatch,re:Dictionary,annotations:PackedStringArray) -> void:
	var kw := _keyword_of(kind)
	var pre := _prefix_of(decl.get_string(0),kw)
	#注解独占一行写在声明上方时 _prefix_of 抓不到（@abstract / @rpc(...) 很常见），这里补上
	for a in annotations:
		var ann:String = a.strip_edges()
		if ann != "" and not pre.contains(ann):
			pre = ann + " " + pre
	item.prefix = pre
	match kind:
		ExposeCheck_ScriptInfo.Type.Func, ExposeCheck_ScriptInfo.Type.StaticF, ExposeCheck_ScriptInfo.Type.AbF:
			var sig := _read_signature(lines,index,item.expose_name)
			item.params = sig["params"]
			item.ret_type = sig["ret"]
			#@abstract 可能独占一行写在声明的上一行，_prefix_of 抓不到，这里补上
			if kind == ExposeCheck_ScriptInfo.Type.AbF and not item.prefix.contains("@abstract"):
				item.prefix = "@abstract " + item.prefix
			if kind == ExposeCheck_ScriptInfo.Type.StaticF and not item.prefix.contains("static"):
				item.prefix = "static " + item.prefix
		ExposeCheck_ScriptInfo.Type.Signal:
			#信号也有参数，同样抓下来（没有返回类型）
			var sig2 := _read_signature(lines,index,item.expose_name)
			item.params = sig2["params"]
		ExposeCheck_ScriptInfo.Type.Var:
			var m:RegExMatch = re["var_type"].search(lines[index])
			if m != null:
				item.ret_type = m.get_string(1)


## 读整段函数/信号签名。
## 签名可以跨多行（参数一个一个换行、或者 ")" 和 "-> 类型:" 单独一行），所以不能只看一行。
## 返回 { "params": PackedStringArray（原样保留的参数文本）, "ret": String }
static func _read_signature(lines:PackedStringArray,start:int,member_name:StringName) -> Dictionary:
	var buf := ""
	var depth := 0
	var opened := false
	var limit:int = mini(start + 60,lines.size())
	for index in range(start,limit):
		buf += lines[index].strip_edges() + " "
		for i in lines[index].length():
			var ch := lines[index][i]
			if ch == "(":
				depth += 1
				opened = true
			elif ch == ")":
				depth -= 1
		if opened and depth <= 0:
			break
		if not opened and index > start:
			break
	#左括号要从【函数名之后】开始找：注解自己也可能带括号（@rpc("any_peer")）
	var name_at := buf.find(String(member_name))
	var lp := buf.find("(",name_at + String(member_name).length()) if name_at >= 0 else buf.find("(")
	var rp := buf.rfind(")")
	if lp < 0 or rp <= lp:
		return {"params":PackedStringArray(),"ret":""}
	var inner := buf.substr(lp + 1,rp - lp - 1)
	#返回类型：右括号之后到 ":" 之前，形如 " -> bool:"
	var ret := ""
	var tail := buf.substr(rp + 1)
	var colon := tail.find(":")
	if colon >= 0:
		ret = tail.substr(0,colon).strip_edges()
		if ret.begins_with("->"):
			ret = ret.substr(2).strip_edges()
	return {"params":_split_params(inner),"ret":ret}


## 按【顶层】逗号切参数。
## 参数里可能有默认值（字典、数组、字符串、嵌套调用），直接 split(",") 会切碎，
## 所以要看括号层级和引号状态。
static func _split_params(inner:String) -> PackedStringArray:
	var out := PackedStringArray()
	var depth := 0
	var quote := ""
	var cur := ""
	for i in inner.length():
		var ch := inner[i]
		if quote != "":
			cur += ch
			if ch == quote and (i == 0 or inner[i - 1] != "\\"):
				quote = ""
			continue
		if ch == '"' or ch == "'":
			quote = ch
			cur += ch
			continue
		if ch == "(" or ch == "[" or ch == "{":
			depth += 1
		elif ch == ")" or ch == "]" or ch == "}":
			depth -= 1
		if ch == "," and depth == 0:
			if cur.strip_edges() != "":
				out.append(cur.strip_edges())
			cur = ""
			continue
		cur += ch
	if cur.strip_edges() != "":
		out.append(cur.strip_edges())
	return out
#endregion
