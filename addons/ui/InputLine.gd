@tool
extends HBoxContainer
class_name ExposeCheck_InputLine

@export var l_input:LineEdit
@export var r_input:LineEdit 
@export var color_picker:ColorPickerButton

func get_port_info()->ExposeCheck_PortInfo:
	return ExposeCheck_PortInfo.new(l_input.text,r_input.text,color_picker.color)

##设置左侧序号标签，例如 "1:"
func set_index_text(t:String)->void:
	var label := get_node_or_null(^"PanelContainer/index") as Label
	if label != null:
		label.text = t
