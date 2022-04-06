extends Node

const MAX_STEPS_PER_TICK := 20 # Safety limit, in case of excessive loops.
enum { STEP_GOTO, STEP_CALL, STEP_END }

signal started() # Dialogue starts up.
signal ended() # Dialogue has ended.
signal ended_w_msg(msg: String) # Dialogue has ended, and includes ending msg.
signal tick() # Step in a stack. May call multiple lines.
signal flow_started(id: String)
signal flow_ended(id: String)
signal option_selected(option: DialogueLine)
signal on_line(text: DialogueLine)
signal _refresh() # called when dialogues were reloaded, and so we should clear the captions/options.
signal _halt_list_changed()

@export var last_end_message := ""
@export var _execute_mode := false # TODO: Implement this differently.
@export var _started := false
#@export var _ticked := []
@export var _stack := [] # current stack of flows, so we can return to a position in a previous flow.
@export var _halting_for := [] # objects that want the flow to _break
@export var _last_tick_stack := [] # stack of the previous tick, used for saving and rollback.

func _init(em := false) -> void:
	_execute_mode = em

func _ready():
	if not Engine.is_editor_hint() and not _execute_mode:
		Saver._get_state.connect(_save_state)
		Saver._set_state.connect(_load_state)
		Saver.pre_load.connect(_game_loaded)
		Global.started.connect(_game_started)
		Global.ended.connect(_game_ended)
		Dialogues.reloaded.connect(_dialogues_reloaded)

func _save_state(state: Dictionary):
	state["DS"] = {
		stack=_last_tick_stack,
		started=_started,
		last_end_message=last_end_message,
	}

func _load_state(state: Dictionary):
	_stack = state["DS"].stack
	_started = state["DS"].started
	last_end_message = state["DS"].last_end_message

func _dialogues_reloaded():
	_refresh.emit()
	_halting_for.clear()
	_halt_list_changed.emit()
	_stack = _last_tick_stack.duplicate(true)

func _game_loaded():
	end("LOADING")

func _game_started():
	if Dialogues.has_dialogue_flow(Soot.M_START):
		execute(Soot.M_START)
	else:
		push_error("There is no '%s' flow." % Soot.M_START)

func _game_ended():
	end("GAME_ENDED")

func is_halted() -> bool:
	return len(_halting_for) > 0

func halt(halter: Object):
	if not _execute_mode and not halter in _halting_for:
		_halting_for.append(halter)
		_halt_list_changed.emit()

func unhalt(halter: Object):
	if not _execute_mode and halter in _halting_for:
		_halting_for.erase(halter)
		_halt_list_changed.emit()

func is_active() -> bool:
	return len(_stack) != 0

func get_current_dialogue() -> Dialogue:
	return null if not len(_stack) else Dialogues.get_dialogue(_stack[-1].d_id)

func _process(_delta: float) -> void:
	_tick()

func start(id: String):
	if is_active():
		push_warning("Already started.")
		return
	
	# start dialogue
	if Soot.is_path(id):
		goto(id, STEP_GOTO)
	
	# go to first flow of dialogue
	else:
		var d := Dialogues.get_dialogue(id)
		if not d.has_flows():
			push_error("No flows in '%s'." % id)
		else:
			var first = Dialogues.get_dialogue(id).flows.keys()[0]
			goto(Soot.join_path([id, first]), STEP_GOTO)

func can_do(command: String) -> bool:
	return command.begins_with(Soot.FLOW_GOTO)\
		or command.begins_with(Soot.FLOW_CALL)\
		or command.begins_with(Soot.FLOW_ENDD)

func do(command: String):
	# => goto
	if command.begins_with(Soot.FLOW_GOTO):
		goto(command.trim_prefix(Soot.FLOW_GOTO).strip_edges(), STEP_GOTO)
	# == call
	elif command.begins_with(Soot.FLOW_CALL):
		goto(command.trim_prefix(Soot.FLOW_CALL).strip_edges(), STEP_CALL)
	# >< end
	elif command.begins_with(Soot.FLOW_ENDD):
		end(command.trim_prefix(Soot.FLOW_ENDD).strip_edges())
	else:
		push_error("Don't know what to do with '%s'." % command)

func goto(dia_flow: String, step_type: int = STEP_GOTO) -> bool:
	return _goto(dia_flow, step_type)

func _goto(dia_flow: String, step_type: int = STEP_GOTO) -> bool:
	if not Soot.is_path(dia_flow):
		push_error("Missing part of flow path: '%s'." % dia_flow)
		return false
	
	var p := Soot.split_path(dia_flow)
	var d_id := p[0]
	var flow := p[1]
	
	if not Dialogues.has_dialogue(d_id):
		push_error("No dialogue %s." % d_id)
		return false
	
	var d := Dialogues.get_dialogue(d_id)
	if not d.has_flow(flow):
		push_error("No flow '%s' in '%s'." % [flow, d_id])
		return false
	
	var lines := d.get_flow_lines(flow)
	if not len(lines):
		push_error("Can't find lines for %s." % flow)
		return false
	
	# if the stack is cleared, it means this was a "goto" not a "call"
	if step_type == STEP_GOTO:
		while len(_stack):
			_pop()
	
	_push(d_id, flow, lines, step_type)
	return true

func end(msg := ""):
	if _started:
		last_end_message = msg
		_started = false
		_stack.clear()
		if not _execute_mode:
			_halting_for.clear()
			_halt_list_changed.emit()
			ended.emit()
			ended_w_msg.emit(msg)

# select an option, adding it's lines to the stack
func select_option(option: DialogueLine):
	var o := option._data
	if "then" in o:
		_push(option._dialogue_id, "%OPTION%", o.then, STEP_CALL)
	if not _execute_mode:
		option_selected.emit(option)

func _pop():
	var last: Dictionary = _stack.pop_back()
	
	# a flow ended
	if not _execute_mode and last.type == STEP_GOTO:
		flow_ended.emit(Soot.join_path([last.d_id, last.flow]))

func _push(d_id: String, flow: String, lines: Array, type: int):
	_stack.append({ d_id=d_id, flow=flow, lines=lines, type=type, step=0 })
	
	# a flow started
	if not _execute_mode and type == STEP_GOTO:
		await get_tree().process_frame
		flow_started.emit(Soot.join_path([d_id, flow]))

func _tick():
	if not _execute_mode and _started:
		# has finished?
		if not len(_stack):
			end()
		
		# is start of tick?
		if len(_stack) and not is_halted():
			_last_tick_stack = _stack.duplicate(true)
			tick.emit()
	
	var safety := MAX_STEPS_PER_TICK
	while (_started or _execute_mode) and len(_stack):
		if not _execute_mode and is_halted():
			break
		
		safety -= 1
		if safety <= 0:
			push_error("Tripped safety! Increase MAX_STEPS_PER_TICK if necessary.", safety)
			break
		
		var line := _pop_next_line()
		
		if not len(line) or not len(line.line):
			continue
		
		match line.line.type:
			"action":
				StringAction.do(line.line.action)
				
			"goto":
				# call main stack, since this could be run in _execute_mode
				DialogueStack._goto(line.line.goto, STEP_GOTO)
				
			"call":
				# call main stack, since this could be run in _execute_mode
				DialogueStack._goto(line.line.call, STEP_CALL)
			
			"end":
				end(line.line.end)
				break
			
			"text":
				if not _execute_mode:
					if "action" in line.line:
						for a in line.line.action:
							StringAction.do(a)
					
					on_line.emit(DialogueLine.new(line.d_id, line.line))
			
			_:
				push_warning("Huh? %s %s" % [line.line.keys(), line.line])
	
	# emit start trigger
	if not _execute_mode and len(_stack) and not _started:
		_started = true
		started.emit()

# forcibly run a flow. usefuly for setting up scenes from a .soot file.
# TODO: do this differently.
func execute(id: String):
	if Dialogues.has_dialogue_flow(id):
		var d = load("res://addons/sooty_engine/autoloads/DialogueStack.gd").new(true)
		d.start(id)
		d._tick()

func _pop_next_line() -> Dictionary:
	# only show lines that pass their {{condition}}.
	var safety := 1000
	while len(_stack):
		safety -= 1
		if safety <= 0:
			push_error("Popped safety.")
			break
		
		# remove last step, and potentially end the flow.
		var step_info: Dictionary = _stack[-1]
		if step_info.step >= len(step_info.lines):
			_pop()
			continue
		
		var dilg := Dialogues.get_dialogue(step_info.d_id)
		var line: Dictionary = dilg.get_line(step_info.lines[step_info.step])
		var d_id: String = step_info.d_id
		var flow: String = step_info.flow
		step_info.step += 1
		
		var out := {d_id=d_id, flow=flow, line=line}
		
		# 'if' 'elif' 'else' chain
		if line.type == "if":
			var d := Dialogues.get_dialogue(d_id)
			for i in len(line.conds):
				if StringAction._test(line.conds[i]):
					_push(d.id, flow, line.cond_lines[i], STEP_CALL)
					return {}
		
		# match chain
		elif line.type == "match":
			var match_result = State._eval(line.match)
			for i in len(line.cases):
				var case = line.cases[i]
				if case == "_" or UType.is_equal(match_result, State._eval(case)):
					_push(d_id, flow, line.case_lines[i], STEP_CALL)
					return {}
		
		# has a condition
		elif "cond" in line:
			if StringAction._test(line.cond):
				return out
		
		else:
			return out
	
	return {}
