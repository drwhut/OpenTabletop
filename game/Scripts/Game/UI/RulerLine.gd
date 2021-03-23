# open-tabletop
# Copyright (c) 2020-2021 Benjamin 'drwhut' Beddows
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

extends Control

onready var _label = $Label
onready var _texture = $Texture

var point1: Vector3
var point2: Vector3

# Update the position and scale of the ruler on the screen.
# camera: The camera being used.
func update_ruler(camera: Camera) -> void:
	var line_behind_camera = camera.is_position_behind(point1) or camera.is_position_behind(point2)
	_label.visible = not line_behind_camera
	if not line_behind_camera:
		var point1_2d = camera.unproject_position(point1)
		var point2_2d = camera.unproject_position(point2)
		var line = point2_2d - point1_2d
		_texture.rect_position = point1_2d
		_texture.rect_size.x = line.length()
		if line.x != 0:
			var angle = atan(line.y / line.x)
			if line.x < 0:
				angle += PI
			_texture.rect_rotation = rad2deg(angle)
		
		_label.rect_position = point2_2d
		var measure_cm = (point2 - point1).length()
		var measure_in = 0.3937008 * measure_cm
		_label.text = "%.1f cm\n%.1f in" % [measure_cm, measure_in]
	else:
		_texture.rect_size.x = 0
