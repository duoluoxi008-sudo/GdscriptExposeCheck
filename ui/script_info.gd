extends Resource
class_name ExposeCheck_ScriptInfo

##成员种类表。【唯一真相】—— 编辑器 UI、蓝图、CLI 全从这儿取，别再各写一份。
##   id    : 数据键，**全 ASCII**。写进蓝图的 "kind"、port_types 的键、ContainerBlock.member_kind，
##           一律不翻译、不本地化。改它等于改文件格式。
##   type  : 中文显示名（源语言）
##   en    : 英文显示名
##   field : 本类里存这类成员的数组字段
const KIND_TABLE:Array[Dictionary] = [
	{"id":"const",       "type":"常量",     "en":"Constant",      "field":"expose_const_name_arr"},
	{"id":"enum",        "type":"枚举",     "en":"Enum",          "field":"expose_enum_name_arr"},
	{"id":"signal",      "type":"信号",     "en":"Signal",        "field":"expose_signal_name_arr"},
	{"id":"var",         "type":"变量",     "en":"Variable",      "field":"expose_var_name_arr"},
	{"id":"func",        "type":"函数",     "en":"Function",      "field":"expose_func_name_arr"},
	{"id":"ab_func",     "type":"抽象函数", "en":"Abstract Func", "field":"expose_ab_func_name_arr"},
	{"id":"static_func", "type":"静态函数", "en":"Static Func",   "field":"expose_st_func_name_arr"},
]


##按 id 取一条种类定义；找不到返回 {}
static func kind_of(id:String) -> Dictionary:
	for k in KIND_TABLE:
		if k["id"] == id:
			return k
	return {}


##中文显示名 → id。老蓝图迁移要用（v2 的 "kind" 存的是中文）。
static func id_of_type(zh:String) -> String:
	for k in KIND_TABLE:
		if k["type"] == zh:
			return k["id"]
	return zh

##脚本文件名，为路径脚本
var file_name:StringName = ""
##脚本路径最后的.gd文件名
var short_name:String = ""
##如果出现了不同路径下同样名字的.gd则为true,就会让两个脚本显示原本的file_name,为false则显示short_name
var is_same_short_name:bool = false
##提示字符串
var hint_string:String = ""
##class_name或者class
var class_name_string:StringName = ""
##父类的显示名（extends 后面那个标识符）
var father_class_name_string:StringName = ""
##父类的脚本路径，只有用户自定义类才有；"" 表示基类是原生类
var father_script_path:StringName = ""
##本类是内部类时它自己的名字；顶层脚本为空
var inner_name:StringName = ""
##本类在图上的唯一 key。顶层 = 脚本路径；内部类 = 脚本路径::内部类名（再嵌套就继续接 ::）
var node_key:StringName = ""
##父类在图上的唯一 key；"" 表示基类是原生类，不用建父节点
var father_node_key:StringName = ""
##暴露出来的信号名
var expose_signal_name_arr:Array[ExposeCheck_ExposeNameAndDsharpHint] = []
##暴露出来的函数名
var expose_func_name_arr:Array[ExposeCheck_ExposeNameAndDsharpHint] = []
##暴露出来的抽象函数名
var expose_ab_func_name_arr:Array[ExposeCheck_ExposeNameAndDsharpHint] = []
##暴露出来的静态函数名
var expose_st_func_name_arr:Array[ExposeCheck_ExposeNameAndDsharpHint] = []
##暴露出来的变量名
var expose_var_name_arr:Array[ExposeCheck_ExposeNameAndDsharpHint] = []
##暴露出来的常量名
var expose_const_name_arr:Array[ExposeCheck_ExposeNameAndDsharpHint] = []
##暴露出来的枚举名
var expose_enum_name_arr:Array[ExposeCheck_ExposeNameAndDsharpHint] = []

##暴露出来的内部类
var expose_inner_class:Dictionary[StringName,ExposeCheck_ScriptInfo] = {}

##成员名 → 声明所在行号（0 起，和源码 split("\n") 的下标一致）。
##记录【所有】声明，不只是暴露的那些 —— 生成代码存根前得先判断「这个成员是不是已经存在」。
var decl_lines:Dictionary[StringName,int] = {}

enum Type {Var,Const,Enum,Signal,Func,StaticF,AbF,InClass}

## 返回新建的 ExposeCheck_ScriptInfo：只有 Type.InClass 会在 expose_inner_class 里建好内部类的 ExposeCheck_ScriptInfo 并返回它，
## 其余类型返回 null（它们要填的就是当前这个 ExposeCheck_ScriptInfo 本身）。
func add_new_expose_name(name:StringName,hint:String,type:Type)->ExposeCheck_ScriptInfo:
	var item = ExposeCheck_ExposeNameAndDsharpHint.new(name,hint)
	match type:
		Type.Var:
			expose_var_name_arr.append(item)
		Type.Signal:
			expose_signal_name_arr.append(item)
		Type.Func:
			expose_func_name_arr.append(item)
		Type.Const:
			expose_const_name_arr.append(item)
		Type.Enum:
			expose_enum_name_arr.append(item)
		Type.StaticF:
			expose_st_func_name_arr.append(item)
		Type.AbF:
			expose_ab_func_name_arr.append(item)
		Type.InClass:
			#内部类和普通类一样对待：有自己的节点、自己的成员、自己的继承链。
			#它没有独立文件，所以 file_name 沿用外层脚本路径（这样 md5 / 存在性检查才有意义），
			#靠 node_key 里的「脚本路径::内部类名」把它和外层区分开。
			var inner_class:ExposeCheck_ScriptInfo = ExposeCheck_ScriptInfo.new()
			inner_class.class_name_string = name
			inner_class.hint_string = hint
			inner_class.inner_name = name
			inner_class.file_name = file_name
			inner_class.node_key = StringName("%s::%s" % [String(node_key),String(name)])
			inner_class.short_name = "%s:%s" % [short_name,String(name)]
			#默认父 = 外类（归属关系）。_scan_lines 里若写了 class Inner extends X 会覆盖成 X。
			inner_class.father_node_key = node_key
			inner_class.father_script_path = file_name
			inner_class.father_class_name_string = class_name_string if class_name_string != "" else StringName(short_name)
			expose_inner_class[name] = inner_class
			return inner_class
	return null
