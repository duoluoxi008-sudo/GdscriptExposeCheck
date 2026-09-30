extends Resource
class_name ExposeCheck_PortInfo

var left_mean:String = ""
var right_mean:String = ""
var color:Color = Color.WHITE

func _init(l_s:String,r_s:String,c:Color) -> void:
		left_mean = l_s
		right_mean = r_s
		color = c
	
