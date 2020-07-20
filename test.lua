local pl = require 'pl.import_into' ()

local function lex_init(file, rules)
	local state = {
		file = file;
		rules = rules;
		tokens = {n = 0; next = 1;};
		buffer = '';
		buffer_pos = 1;
		linear_pos = 1;
	}
	return state
end
local function lex_read(state, n)
	if not n then
		n = state.rules.lookahead
	end
	while #state.buffer - state.buffer_pos + 1 < n do
		local new = state.file:read(1024 * 1024)
		if new == nil then
			break
		end
		if state.buffer_pos > 1 then
			state.buffer = state.buffer:sub(state.buffer_pos)
			state.buffer_pos = 1
		end
		state.buffer = state.buffer .. new
	end
end
local function lex_match(state, pat)
	local match = table.pack(string.match(state.buffer, '^(' .. pat .. ')', state.buffer_pos))
	if match[1] then
		state.buffer_pos = state.buffer_pos + #match[1]
		state.linear_pos = state.linear_pos + #match[1]
		return table.unpack(match)
	else
		return nil
	end
end
local function lex_peek(state)
	while state.tokens.n < state.tokens.next do
		lex_read(state)
		if #state.buffer - state.buffer_pos + 1 == 0 then
			return nil
		end
		for i = 1, state.rules.n do
			local rule = state.rules[i]
			local start_pos = state.linear_pos
			local match = table.pack(lex_match(state, rule.pat))
			if match[1] then
				if rule.ext_pat then
					local ext_pat = rule.ext_pat
					if ext_pat == true then
						ext_pat = rule.pat
					end
					while state.buffer_pos == #state.buffer + 1 do
						lex_read(state)
						local ext_match = table.pack(lex_match(state, ext_pat))
						if ext_match[1] then
							match.n = match.n + 1
							match[match.n] = ext_match
						else
							break
						end
					end
				end
				rule.act(state, start_pos, table.unpack(match, 1, match.n))
				goto done
			end
		end
		error(('no rule matched: %q'):format(state.buffer:sub(state.buffer_pos)))
		::done::
	end
	return state.tokens[state.tokens.next]
end
local function lex_pull(state)
	local token = lex_peek(state)
	state.tokens[state.tokens.next] = nil
	if state.tokens.next == state.tokens.n then
		state.tokens.n = 0
		state.tokens.next = 1
	else
		state.tokens.next = state.tokens.next + 1
	end
	return token
end
local function lex_switch_rules(state, rules)
	assert(state.tokens.n == 0)
	state.rules = rules
end
local function lex_push_token(state, token)
	state.tokens.n = state.tokens.n + 1
	state.tokens[state.tokens.n] = token
end
local function lex_token(typ) return function(state, start_pos, text, ...)
	lex_push_token(state, {
		type = typ;
		text = text;
		start_pos = start_pos;
		captures = table.pack(...);
	})
end end
local function lex_block(typ) return function(state, start_pos, full_text)
	local n = 0
	while true do
		lex_read(state, 1)
		local text = lex_match(state, '%=+')
		if text then
			n = n + #text
			full_text = full_text .. text
		else
			break
		end
	end
	do
		lex_read(state, 1)
		local text = lex_match(state, '%[')
		if text then
			full_text = full_text .. text
		else
			error(('TODO: buffer = %q'):format(state.buffer))
		end
	end
	local contents = ''
	while true do
		lex_read(state, n + 2)
		local text = lex_match(state, ('%%]%s%%]'):format(('='):rep(n)))
		if text then
			full_text = full_text .. text
			break
		end
		lex_read(state, 2)
		local text = lex_match(state, '%]?[^%]]*')
		if text then
			if text == '' then
				error('TODO')
			end
			full_text = full_text .. text
			contents = contents .. text
		end
	end
	lex_push_token(state, {
		type = typ;
		text = full_text;
		start_pos = start_pos;
		captures = table.pack(contents);
	})
end end
local function lex_save(state)
	local save = {
		pos = state.file:seek() - #state.buffer + state.buffer_pos - 1;
		rules = state.rules;
		tokens = {n = 0;};
		linear_pos = state.linear_pos;
	}
	for i = state.tokens.next, state.tokens.n do
		save.tokens.n = save.tokens.n + 1
		save.tokens[save.tokens.n] = state.tokens[i]
	end
	return save
end
local function lex_restore(state, save)
	state.file:seek('set', save.pos)
	state.rules = save.rules
	state.tokens = {n = save.tokens.n; next = 1;}
	for i = 1, save.tokens.n do
		state.tokens[i] = save.tokens[i]
	end
	state.buffer = ''
	state.buffer_pos = 1
	state.linear_pos = save.linear_pos
end
local function lex_make_rules(rules)
	if not rules.n then
		rules.n = #rules
	end
	local n = 1
	for i = 1, rules.n do
		if rules[i].n > n then
			n = rules[i].n
		end
	end
	rules.lookahead = n
	return rules
end
local lex_rules = lex_make_rules {
	{n=1, pat='\'', act=lex_token 'quote'};
	{n=1, pat='"', act=lex_token 'quote'};
	{n=1, pat='%(', act=lex_token 'open_paren'};
	{n=1, pat='%)', act=lex_token 'close_paren'};
	{n=1, pat='{', act=lex_token 'open_brace'};
	{n=1, pat='}', act=lex_token 'close_brace'};
	{n=1, pat='%[', act=lex_token 'open_bracket'};
	{n=1, pat='%]', act=lex_token 'close_bracket'};
	{n=1, pat='%.', act=lex_token 'dot'};
	{n=1, pat=':', act=lex_token 'colon'};
	{n=1, pat=',', act=lex_token 'comma'};
	{n=1, pat=';', act=lex_token 'semicolon'};
	{n=3, pat='%-%-%[', ext_pat='[^\r\n]+', act=lex_block 'block_comment'};
	{n=2, pat='%-%-([^\r\n]*)', ext_pat='([^\r\n]+)', act=lex_token 'line_comment'};
	{n=2, pat='\r?\n', act=lex_token 'newline'};
	{n=1, pat='[^%S\n]+', ext_pat=true, act=lex_token 'linear_ws'};
	{n=1, pat='[^()%[%]{}%s\'",;:%.]+', ext_pat=true, act=lex_token 'identifier'};
}
local lex_rules_string = lex_make_rules {
	{n=1, pat='\'', act=lex_token 'quote'};
	{n=1, pat='"', act=lex_token 'quote'};
	{n=2, pat='\\[nrte\'"\\]', act=lex_token 'escape'};
	{n=1, pat='[^\\\'"]+', ext_pat=true, act=lex_token 'text'};
}

local function lex_indent_init(lex_state)
	local state = {
		lex = lex_state;
		indent = nil;
		pending = nil;
	}
	return state
end
local function lex_indent_peek(state)
	if state.pending then
		return state.pending
	else
		local token = lex_peek(state.lex)
		if state.indent == nil then
			local indent = ''
			while token.type == 'linear_ws' do
				indent = indent .. token.text
				lex_pull(state.lex)
				token = lex_peek(state.lex)
			end
			state.indent = {indent}
		end
		return token
	end
end
local function lex_indent_pull(state)
	local token = lex_indent_peek(state)
	if state.pending then
		state.pending = nil
	else
		lex_pull(state.lex)
		if token and token.type == 'newline' then
			local new_indent = ''
			local eof = not lex_peek(state.lex)
			local next_token
			while true do
				next_token = lex_peek(state.lex)
				if not next_token or next_token.type ~= 'linear_ws' then
					break
				end
				lex_pull(state.lex)
				new_indent = new_indent .. next_token.text
			end
			if next_token and next_token.type ~= 'newline' then
				local cur_indent = state.indent[#state.indent]
				if new_indent == cur_indent then
				elseif new_indent:sub(1, #cur_indent) == cur_indent then
					state.indent[#state.indent + 1] = new_indent
					state.pending = { type = 'indent'; relative = new_indent:sub(#cur_indent + 1); }
				elseif cur_indent:sub(1, #new_indent) == new_indent then
					if #state.indent == 1 and not eof then
						-- the `not eof` is to accept a trailing newline (unix style), which would not have any indentation after it
						error(('dedent below initial level: old = %q, new = %q'):format(cur_indent, new_indent))
					end
					state.indent[#state.indent] = nil
					state.pending = { type = 'dedent'; relative = cur_indent:sub(#new_indent + 1); }
				else
					error(('bad indentation: old = %q, new = %q'):format(cur_indent, new_indent))
				end
			end
		end
	end
	return token
end
local function lex_indent_save(state)
	local save = {
		lex = lex_save(state.lex);
		pending = state.pending;
		indent = {};
	}
	for i = 1, #state.indent do
		save.indent[i] = state.indent[i]
	end
	return save
end
local function lex_indent_restore(state, save)
	lex_restore(state.lex, save.lex)
	state.pending = save.pending
	state.indent = {}
	for i = 1, #save.indent do
		state.indent[i] = save.indent[i]
	end
end

local h = io.open('test.conl', 'r')
local lex_state = lex_init(h, lex_rules)
local lex_indent_state = lex_indent_init(lex_state)
local function is_ws(token)
	if not token then
		return false
	end
	return false
		or token.type == 'linear_ws'
		or token.type == 'newline'
		or token.type == 'line_comment'
		or token.type == 'block_comment'
		or token.type == 'indent'
		or token.type == 'dedent'
end
local function skip_ws()
	while true do
		local token = lex_indent_peek(lex_indent_state)
		if is_ws(token) then
			lex_indent_pull(lex_indent_state)
		else
			break
		end
	end
end
local precedence = {
	decl = {};
	assign = {
		plus = true;
		concat = true;
		assign = true;
	};
	block = {
		plus = true;
		concat = true;
		assign = true;
	};
	plus = {};
	concat = {
		plus = true;
	};
}
do
	local global = {}
	for k, v in pairs(precedence) do
		global[k] = true
	end
	precedence.global = global
end
local parse_expr
local function parse_decl()
	local token = lex_indent_peek(lex_indent_state)
	if not token then return nil end
	if token.type ~= 'identifier' then return nil end
	if token.text ~= 'let' and token.text ~= 'def' then return nil end
	lex_indent_pull(lex_indent_state)
	skip_ws()
	local const = token.text == 'def'
	local save = lex_indent_save(lex_indent_state)
	local ok, name, mod = xpcall(function()
		local mod = parse_expr 'decl'
		assert(mod.type == 'access')
		return mod.name, mod.head
	end, function(err)
		print(err, debug.traceback())
		lex_indent_restore(lex_indent_state, save)
		token = lex_indent_pull(lex_indent_state)
		assert(token.type == 'identifier')
		return token.text, nil
	end)
	skip_ws()
	token = lex_indent_pull(lex_indent_state)
	assert(token.type == 'identifier' and token.text == '=', ('TODO: token = %q'):format(token.text))
	skip_ws()
	local val = parse_expr 'assign'
	return {
		type = 'decl';
		export = false;
		const = const;
		module = mod;
		name = name;
		value = val;
	}
end
local function parse_block(end_token_type)
	local body = {n = 0;}
	while true do
		skip_ws()
		local token = lex_indent_peek(lex_indent_state)
		if token.type == end_token_type then
			lex_indent_pull(lex_indent_state)
			break
		end
		local expr = parse_expr 'block'
		if expr == nil then
			if end_token_type then
				error 'TODO'
			else
				break
			end
		end
		body.n = body.n + 1
		body[body.n] = expr
	end
	return body
end
local function parse_args(end_token_type)
	local args = {n = 0;}
	while true do
		skip_ws()
		local token = lex_indent_peek(lex_indent_state)
		if token.type == end_token_type then
			lex_indent_pull(lex_indent_state)
			break
		end
		args.n = args.n + 1
		args[args.n] = assert(parse_expr 'block')
		token = lex_indent_pull(lex_indent_state)
		if token.type == end_token_type then
			break
		elseif token.type == 'comma' then
		else
			error(('TODO: token.type = %q'):format(token.type))
		end
	end
	return args
end
local function parse_expr_atom()
	local expr = parse_decl()
	if expr then
		return expr
	end

	local token = lex_indent_peek(lex_indent_state)
	if not token then
		return nil
	elseif token.type == 'identifier' then
		lex_indent_pull(lex_indent_state)
		if token.text == 'export' then
			skip_ws()

			local decl = parse_decl()
			if decl then
				decl.export = true
				return decl
			end

			error('TODO')
		elseif token.text:match '^%d+$' then
			local text = token.text
			local token = lex_indent_peek(lex_indent_state)
			if token.type == 'dot' then
				lex_indent_pull(lex_indent_state)
				token = lex_indent_pull(lex_indent_state)
				assert(token.type == 'identifier')
				assert(token.text:match '^%d+$')
				text = text .. '.' .. token.text
			end
			return {
				type = 'number';
				value = tonumber(text);
			}
		else
			return {
				type = 'var';
				name = token.text;
			}
		end
	elseif token.type == 'quote' then
		lex_indent_pull(lex_indent_state)
		local quote = token.text
		lex_switch_rules(lex_state, lex_rules_string)
		local text = ''
		while true do
			token = lex_pull(lex_state)
			if token.type == 'text' then
				text = text .. token.text
			elseif token.type == 'quote' then
				if token.text == quote then
					break
				else
					text = text .. token.text
				end
			else
				error(('TODO: token.type = %q'):format(token.type))
			end
		end
		lex_switch_rules(lex_state, lex_rules)
		return {
			type = 'str';
			text = text;
		}
	elseif token.type == 'open_brace' then
		lex_indent_pull(lex_indent_state)
		skip_ws()
		local save = lex_indent_save(lex_indent_state)
		local ok, args = xpcall(function()
			local args = {n = 0;}
			local token = lex_indent_pull(lex_indent_state)
			assert(token.type == 'open_paren')
			while true do
				local token = lex_indent_pull(lex_indent_state)
				if is_ws(token) then
				elseif token.type == 'identifier' then
					args.n = args.n + 1
					args[args.n] = token.text
					skip_ws()
					local token = lex_indent_pull(lex_indent_state)
					if token.type == 'comma' then
					elseif token.type == 'close_paren' then
						goto args_list_done
					else
						error(('TODO: token.type = %q'):format(token.type))
					end
				elseif token.type == 'close_paren' then
					goto args_list_done
				else
					error(('TODO: token.type = %q'):format(token.type))
				end
			end
			::args_list_done::
			skip_ws()
			token = lex_indent_pull(lex_indent_state)
			assert(token.type == 'identifier' and token.text == 'in')
			return args
		end, function(err)
			print(err, debug.traceback())
			lex_indent_restore(lex_indent_state, save)
			return nil
		end)
		local body = parse_block 'close_brace'
		return {
			type = 'fn';
			args = args;
			body = body;
		}
	elseif token.type == 'open_paren' then
		lex_indent_pull(lex_indent_state)
		local body = parse_block 'close_paren'
		return {
			type = 'block';
			body = body;
		}
	else
		-- error(('TODO: token.type = %q'):format(token.type))
		return nil
	end
end
local function parse_postop(prec)
	local token = lex_indent_peek(lex_indent_state)
	if not token then
		return nil
	elseif token.type == 'open_paren' then
		lex_indent_pull(lex_indent_state)
		local args = parse_args 'close_paren'
		return function(head) return {
			type = 'call';
			fn = head;
			args = args;
		} end
	elseif token.type == 'open_bracket' then
		lex_indent_pull(lex_indent_state)
		local args = parse_args 'close_bracket'
		return function(head) return {
			type = 'index';
			fn = head;
			args = args;
		} end
	elseif token.type == 'identifier' then
		if token.text == '+' then
			if not precedence[prec].plus then return nil end
			lex_indent_pull(lex_indent_state)
			skip_ws()
			local right = assert(parse_expr 'plus')
			return function(head) return {
				type = 'binop';
				op = '+';
				left = head;
				right = right;
			} end
		elseif token.text == '=' then
			if not precedence[prec].assign then return nil end
			lex_indent_pull(lex_indent_state)
			skip_ws()
			local val = assert(parse_expr 'assign')
			return function(head) return {
				type = 'assign';
				to = head;
				val = val;
			} end
		else
			return nil
		end
	elseif token.type == 'dot' then
		lex_indent_pull(lex_indent_state)
		token = lex_indent_peek(lex_indent_state)
		if token and token.type == 'dot' then
			if not precedence[prec].concat then return nil end
			lex_indent_pull(lex_indent_state)
			skip_ws()
			local right = assert(parse_expr 'concat')
			return function(head) return {
				type = 'binop';
				op = '..';
				left = head;
				right = right;
			} end
		end
		local name
		while true do
			local token = lex_indent_pull(lex_indent_state)
			if token.type == 'identifier' then
				name = token.text
				break
			else
				error(('TODO: token.type = %q'):format(token.type))
			end
		end
		return function(head) return {
			type = 'access';
			head = head;
			name = name;
		} end
	else
		return nil
	end
end
function parse_expr(prec)
	assert(type(prec) == 'string', prec)
	assert(precedence[prec], prec)
	local expr = parse_expr_atom()
	if not expr then
		return nil
	end
	while true do
		skip_ws()
		local op = parse_postop(prec)
		if op then
			expr = op(expr)
		else
			break
		end
	end
	return expr
end
local body = {n = 0;}
while true do
	local expr = parse_expr 'global'
	if expr then
		body.n = body.n + 1
		body[body.n] = expr
	else
		break
	end
end
assert(lex_indent_peek(lex_indent_state) == nil)
print(pl.pretty.write(body))

local Expr = {
	Sscope = {};
	Sscope_i = {};
	Sconst = {};
	Stype = {};
}
local str_type = {
	type = 'str_t';
}
local number_type = {
	type = 'number_t';
}
local module_type = {
	type = 'module_t';
}
local function make_scope(parent, parent_i)
	local scope = {
		bindings_expr = { n = 0; };
		children = {};
		module = {
			bindings_expr = { n = 0; };
		};
		parent = parent;
		parent_i = parent_i;
	}
	if parent then
		parent.children[parent_i] = scope
	end
	do
		local linear = {
			start_at = 0;
			bindings_expr = { n = 0; };
		}
		scope.linear_first = linear
		scope.linear_last = linear
	end
	return scope
end
local function pass_1(expr, scope, scope_i)
	expr[Expr.Sscope] = scope
	expr[Expr.Sscope_i] = scope_i
	if expr.type == 'decl' then
		local n = 0
		if expr.module then
			n = n + 1 + pass_1(expr.module, scope, scope_i + n + 1)
		end
		n = n + 1 + pass_1(expr.value, scope, scope_i + n + 1)
		if expr.export then
			scope.module.bindings_expr.n = scope.module.bindings_expr.n + 1
			scope.module.bindings_expr[scope.module.bindings_expr.n] = expr
		end
		if expr.const then
			scope.bindings_expr.n = scope.bindings_expr.n + 1
			scope.bindings_expr[scope.bindings_expr.n] = expr
		else
			local new_linear = {
				start_at = scope_i + n + 1;
				prev = scope.linear_last;
				bindings_expr = { n = 1; expr };
			}
			scope.linear_last.next = new_linear
			scope.linear_last.end_before = scope_i + n + 1
			scope.linear_last = new_linear
		end
		return n
	elseif expr.type == 'fn' then
		local i = 0
		local new_scope = make_scope(scope, scope_i)
		expr.inner_scope = new_scope
		for i = 1, expr.body.n do
			i = i + 1 + pass_1(expr.body[i], new_scope, i)
		end
		return 0
	elseif expr.type == 'binop' then
		local n = 0
		n = n + 1 + pass_1(expr.left, scope, scope_i + n + 1)
		n = n + 1 + pass_1(expr.right, scope, scope_i + n + 1)
		return n
	elseif expr.type == 'str' or expr.type == 'var' or expr.type == 'number' then
		return 0
	elseif expr.type == 'call' then
		local n = 0
		n = n + 1 + pass_1(expr.fn, scope, scope_i + n + 1)
		for i = 1, expr.args.n do
			n = n + 1 + pass_1(expr.args[i], scope, scope_i + n + 1)
		end
		return n
	elseif expr.type == 'access' then
		return 1 + pass_1(expr.head, scope, scope_i + 1)
	else
		error(('TODO: expr.type = %s'):format(expr.type))
	end
end
local resolve, const_fold, type_infer
function resolve(expr)
	if expr.type == 'var' then
		if expr.decl then return end
		local scope, scope_i = expr[Expr.Sscope], expr[Expr.Sscope_i]
		while scope do
			local linear = scope.linear_last
			while linear.start_at > scope_i do
				linear = linear.prev
			end
			while linear do
				for i = 1, linear.bindings_expr.n do
					local decl = linear.bindings_expr[i]
					if not decl.module and decl.name == expr.name then
						expr.decl = decl
						return
					end
				end
				linear = linear.prev
			end
			for i = 1, scope.bindings_expr.n do
				local decl = scope.bindings_expr[i]
				if not decl.module and decl.name == expr.name then
					expr.decl = decl
					return
				end
			end
			scope, scope_i = scope.parent, scope.parent_i
		end
		error(('TODO: var name: %q'):format(expr.name))
	elseif expr.type == 'access' then
		type_infer(expr.head)
		local head_t = expr.head[Expr.Stype]
		if head_t.type == 'module_t' then
			if expr.dynamic then return end
			const_fold(expr.head)
			local module = expr.head[Expr.Sconst]
			assert(module)
			assert(module.type == 'module')
			local dynamic = {n = 0;}
			expr.dynamic = dynamic
			local function check(decl, m)
				if not decl.module and not module then return false end
				if decl.name ~= expr.name then return false end
				if decl.module then
					const_fold(decl.module)
					m = decl.module[Expr.Sconst]
					if not m then
						dynamic.n = dynamic.n + 1
						dynamic[dynamic.n] = decl
						return false
					end
				end
				if m.module ~= module.module then return false end
				expr.decl = decl
				return true
			end
			local scope, scope_i = expr[Expr.Sscope], expr[Expr.Sscope_i]
			while scope do
				local linear = scope.linear_last
				while linear.start_at > scope_i do
					linear = linear.prev
				end
				while linear do
					for i = 1, linear.bindings_expr.n do
						if check(linear.bindings_expr[i]) then
							return
						end
					end
					linear = linear.prev
				end
				for i = 1, scope.bindings_expr.n do
					if check(scope.bindings_expr[i]) then
						return
					end
				end
				scope, scope_i = scope.parent, scope.parent_i
			end
			local ext = module.extension
			while ext do
				for i = 1, ext.module.bindings_expr.n do
					if check(ext.module.bindings_expr[i]) then
						return
					end
				end
				ext = ext.prev
			end
			for i = 1, module.module.bindings_expr.n do
				if check(module.module.bindings_expr[i], module) then
					return
				end
			end
			if dynamic.n == 0 then
				error(('TODO: expr: module = %s, name = %q'):format(module.module, expr.name))
			end
		else
			error(('TODO: head_t.type = %s'):format(head_t.type))
		end
	elseif expr.type == 'decl' or expr.type == 'call' or expr.type == 'fn' or expr.type == 'number' then
	else
		error(('TODO: expr.type = %s'):format(expr.type))
	end
end
function const_fold(expr)
	if expr[Expr.Sconst] then return end
	resolve(expr)
	if expr.type == 'decl' then
		const_fold(expr.value)
		expr[Expr.Sconst] = expr.value[Expr.Sconst]
	elseif expr.type == 'fn' then
		expr[Expr.Sconst] = {
			type = 'fn';
			inner_scope = expr.inner_scope;
		}
	elseif expr.type == 'binop' then
		const_fold(expr.left)
		const_fold(expr.right)
		local l, r = expr.left[Expr.Sconst], expr.right[Expr.Sconst]
		if l and r then
			error(('TODO: op = %s'):format(expr.op))
		end
	elseif expr.type == 'str' then
		expr[Expr.Sconst] = {
			type = 'str';
			text = expr.text;
		}
	elseif expr.type == 'number' then
		expr[Expr.Sconst] = {
			type = 'number';
			value = expr.value;
		}
	elseif expr.type == 'var' then
		-- TODO: mutability
		const_fold(expr.decl.value)
		expr[Expr.Sconst] = expr.decl.value[Expr.Sconst]
	elseif expr.type == 'call' then
		const_fold(expr.fn)
		local fn = expr.fn[Expr.Sconst]
		if not fn then return end
		if fn.type == 'builtin:module' then
			assert(expr.args.n == 1)
			const_fold(expr.args[1])
			local body = expr.args[1][Expr.Sconst]
			if body.type ~= 'fn' then return end
			expr[Expr.Sconst] = {
				type = 'module';
				module = body.inner_scope.module;
				extensions = {n = 0;};
			}
		else
			error(('TODO: fn.type = %s'):format(fn.type))
		end
	elseif expr.type == 'access' then
		local head_t = expr.head[Expr.Stype]
		if head_t.type == 'module_t' then
			assert(expr.decl)
			-- TODO: mutability
			const_fold(expr.decl)
			local v = expr.decl[Expr.Sconst]
			if v and v.type == 'module' then
				local ext_v = {}
				for k, v in pairs(v) do
					ext_v[k] = v
				end
				ext_v.extension = {
					module = expr.decl[Expr.Sscope].module;
					prev = v.extension;
				}
				v = ext_v
			end
			expr[Expr.Sconst] = v
		else
			error(('TODO: head_t.type = %s'):format(head_t.type))
		end
	else
		error(('TODO: expr.type = %s'):format(expr.type))
	end
end
function type_infer(expr)
	if expr[Expr.Stype] then return end
	resolve(expr)
	if expr.type == 'decl' then
		type_infer(expr.value)
		expr[Expr.Stype] = expr.value[Expr.Stype]
	elseif expr.type == 'fn' then
		for i = 1, expr.body.n do
			type_infer(expr.body[i])
		end
		expr[Expr.Stype] = {
			type = 'fn_t';
		}
	elseif expr.type == 'binop' then
		type_infer(expr.left)
		type_infer(expr.right)
		local l, r = expr.left[Expr.Stype], expr.right[Expr.Stype]
		error(('TODO: op = %s'):format(expr.op))
	elseif expr.type == 'str' then
		expr[Expr.Stype] = str_type
	elseif expr.type == 'number' then
		expr[Expr.Stype] = number_type
	elseif expr.type == 'var' then
		-- TODO: mutability
		type_infer(expr.decl)
		expr[Expr.Stype] = expr.decl[Expr.Stype]
	elseif expr.type == 'call' then
		type_infer(expr.fn)
		for i = 1, expr.args.n do
			type_infer(expr.args[i])
		end
		local fn_t = expr.fn[Expr.Stype]
		if fn_t.type == 'fn_t' then
			-- TODO: polymorphism
			expr[Expr.Stype] = fn_t.ret
		else
			error(('TODO: fn_t.type = %s'):format(fn_t.type))
		end
	elseif expr.type == 'access' then
		local head_t = expr.head[Expr.Stype]
		if head_t.type == 'module_t' then
			assert(expr.decl)
			type_infer(expr.decl)
			expr[Expr.Stype] = expr.decl[Expr.Stype]
		else
			error(('TODO: head_t.type = %s'):format(head_t.type))
		end
	else
		error(('TODO: expr.type = %s'):format(expr.type))
	end
end
local global = make_scope()
do
	global.bindings_expr.n = global.bindings_expr.n + 1
	global.bindings_expr[global.bindings_expr.n] = {
		type = 'decl';
		export = false;
		const = true;
		module = nil;
		name = 'module';
		value = {
			type = 'const';
			[Expr.Stype] = {
				type = 'fn_t';
				ret = {
					type = 'module_t';
				};
			};
			[Expr.Sconst] = {
				type = 'builtin:module';
			};
			-- [Expr.Sscope] = global;
			-- [Expr.Sscope_i] = 0;
		};
		-- [Expr.Sscope] = global;
		-- [Expr.Sscope_i] = 0;
	}
end
local scope = make_scope(global, 0)
do -- pass 1
	local i = 0
	for j = 1, body.n do
		i = i + pass_1(body[j], scope, i) + 1
	end
	print(i)
end
for i = 1, body.n do
	type_infer(body[i])
	const_fold(body[i])
	print(pl.pretty.write(body[i][Expr.Sconst]))
end
