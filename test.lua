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
	{n=1, pat=',', act=lex_token 'comma'};
	{n=1, pat='%.', act=lex_token 'dot'};
	{n=3, pat='%-%-%[', ext_pat='[^\r\n]+', act=lex_block 'block_comment'};
	{n=2, pat='%-%-([^\r\n]*)', ext_pat='([^\r\n]+)', act=lex_token 'line_comment'};
	{n=2, pat='\r?\n', act=lex_token 'newline'};
	{n=1, pat='[^%S\n]+', ext_pat=true, act=lex_token 'linear_ws'};
	{n=1, pat='[^()%[%]{}%s\'",%.]+', ext_pat=true, act=lex_token 'identifier'};
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
local parse_expr
local function parse_expr_atom()
	local token = lex_indent_peek(lex_indent_state)
	if not token then
		return nil
	elseif token.type == 'identifier' then
		lex_indent_pull(lex_indent_state)
		if token.text == 'let' then
			local name
			while true do
				local token = lex_indent_pull(lex_indent_state)
				if token.type == 'identifier' then
					name = token.text
					break
				elseif token.type == 'linear_ws' then
				else
					error(('TODO: token.type = %q'):format(token.type))
				end
			end
			skip_ws()
			while true do
				local token = lex_indent_pull(lex_indent_state)
				if token.type == 'identifier' and token.text == '=' then
					break
					error(('TODO: token.type = %q'):format(token.type))
				end
			end
			skip_ws()
			local val = assert(parse_expr(0))
			return {
				type = 'let';
				name = name;
				val = val;
			}
		elseif token.text == 'const' then
			skip_ws()
			local token = lex_indent_pull(lex_indent_state)
			assert(token.type == 'identifier')
			local name = token.text
			skip_ws()
			local token = lex_indent_pull(lex_indent_state)
			assert(token.type == 'identifier' and token.text == '=')
			skip_ws()
			local val = assert(parse_expr(0))
			return {
				type = 'const';
				name = name;
				val = val;
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
		local ok, args = pcall(function()
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
		end)
		if ok then
		else
			print(args, debug.traceback())
			args = nil
			lex_indent_restore(lex_indent_state, save)
		end
		local body = {n = 0;}
		while true do
			skip_ws()
			local token = lex_indent_peek(lex_indent_state)
			if token.type == 'close_brace' then
				lex_indent_pull(lex_indent_state)
				goto done
			end
			body.n = body.n + 1
			body[body.n] = assert(parse_expr(0))
		end
		::done::
		return {
			type = 'fn';
			args = args;
			body = body;
		}
	elseif token.type == 'open_paren' then
		lex_indent_pull(lex_indent_state)
		local body = {n = 0;}
		while true do
			skip_ws()
			local token = lex_indent_peek(lex_indent_state)
			if token.type == 'close_paren' then
				lex_indent_pull(lex_indent_state)
				goto done
			end
			body.n = body.n + 1
			body[body.n] = assert(parse_expr(0))
		end
		::done::
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
		local args = {n = 0;}
		while true do
			skip_ws()
			local token = lex_indent_peek(lex_indent_state)
			if token.type == 'close_paren' then
				lex_indent_pull(lex_indent_state)
				goto args_done
			end
			args.n = args.n + 1
			args[args.n] = assert(parse_expr(0))
			token = lex_indent_pull(lex_indent_state)
			if token.type == 'close_paren' then
				goto args_done
			elseif token.type == 'comma' then
				break
			else
				error(('TODO: token.type = %q'):format(token.type))
			end
		end
		::args_done::
		return function(head) return {
			type = 'call';
			fn = head;
			args = args;
		} end
	elseif token.type == 'open_bracket' then
		lex_indent_pull(lex_indent_state)
		local args = {n = 0;}
		while true do
			skip_ws()
			local token = lex_indent_peek(lex_indent_state)
			if token.type == 'close_paren' then
				lex_indent_pull(lex_indent_state)
				goto args_done
			end
			args.n = args.n + 1
			args[args.n] = assert(parse_expr(0))
			token = lex_indent_pull(lex_indent_state)
			if token.type == 'close_bracket' then
				goto args_done
			elseif token.type == 'comma' then
			else
				error(('TODO: token.type = %q'):format(token.type))
			end
		end
		::args_done::
		return function(head) return {
			type = 'index';
			fn = head;
			args = args;
		} end
	elseif token.type == 'identifier' then
		if token.text == '+' then
			lex_indent_pull(lex_indent_state)
			skip_ws()
			local right = assert(parse_expr(0))
			return function(head) return {
				type = 'add';
				left = head;
				right = right;
			} end
		elseif token.text == '=' then
			lex_indent_pull(lex_indent_state)
			skip_ws()
			local val = assert(parse_expr(0))
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
	local expr = parse_expr(0)
	if expr then
		body.n = body.n + 1
		body[body.n] = expr
	else
		break
	end
end
assert(lex_indent_peek(lex_indent_state) == nil)
print(pl.pretty.write(body))
