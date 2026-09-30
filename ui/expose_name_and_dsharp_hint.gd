extends Resource
class_name ExposeCheck_ExposeNameAndDsharpHint

var expose_name:StringName = ""
var Dsharp_hint:String = ""

##参数的原始文本（含默认值），例如 ["amount: int", "source: Node2D"]。
##故意不解析成结构：生成存根时原样抄回去最不容易出错。
var params:PackedStringArray = PackedStringArray()
##函数的返回类型 / 变量的显式类型；没写（含 `:=` 推导）就是 ""
var ret_type:String = ""
##声明关键字之前的部分：注解 + 修饰符，例如 "@export "、"static "、"@abstract "
var prefix:String = ""

func _init(name:StringName,hint:String)->void:
	expose_name = name
	Dsharp_hint = hint
