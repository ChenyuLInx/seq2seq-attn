require 'nn'
require 'string'
require 'nngraph'

dofile 'models.lua'
dofile 'data.lua'

path = require 'pl.path'
stringx = require 'pl.stringx'

cmd = torch.CmdLine()

-- file location
cmd:option('-model', 'seq2seq_lstm_attn.t7.', [[Path to model .t7 file]])
cmd:option('-src_file', '', [[Source sequence to decode (one line per sequence)]])
cmd:option('-targ_file', '', [[True target sequence (optional)]])
cmd:option('-output_file', 'pred.txt', [[Path to output the predictions (each line will be the decoded sequence]])
cmd:option('-src_dict', 'data/demo.src.dict', [[Path to source vocabulary (*.src.dict file)]])
cmd:option('-targ_dict', 'data/demo.targ.dict', [[Path to target vocabulary (*.targ.dict file)]])
cmd:option('-char_dict', 'data/demo.char.dict', [[If using chars, path to character vocabulary (*.char.dict file)]])
cmd:option('-gpuid', -1, [[ID of the GPU to use (-1 = use CPU)]])
cmd:option('-beam', 1,[[Beam size]])
cmd:option('-max_sent_l', 250, [[Maximum sentence length. If any sequences in srcfile are longer than this then it will error out]])
cmd:option('-keyword_dict', '',[[path to keyword dictionary]])

-- vector spec
cmd:option('-vector', 0, [[If one output the vector]])
cmd:option('-vector_file', '', [[output_file for vector]])
function copy(orig)
  local orig_type = type(orig)
  local copy
  if orig_type == 'table' then
    copy = {}
    for orig_key, orig_value in pairs(orig) do
      copy[orig_key] = orig_value
    end
  else
    copy = orig
  end
  return copy
end

local StateAll = torch.class("StateAll")

function StateAll.initial(start)
  return {start}
end

function StateAll.advance(state, token)
  local new_state = copy(state)
  table.insert(new_state, token)
  return new_state
end

function StateAll.disallow(out)
  local bad = {1, 3} -- 1 is PAD, 3 is BOS
  for j = 1, #bad do
    out[bad[j]] = -1e9
  end
end

function StateAll.same(state1, state2)
  for i = 2, #state1 do
    if state1[i] ~= state2[i] then
      return false
    end
  end
  return true
end

function StateAll.next(state)
  return state[#state]
end

function StateAll.heuristic(state)
  return 0
end

function StateAll.print(state)
  for i = 1, #state do
    io.write(state[i] .. " ")
  end
  print()
end

-- Convert a flat index to a row-column tuple.
function flat_to_rc(v, flat_index)
  local row = math.floor((flat_index - 1) / v:size(2)) + 1
  return row, (flat_index - 1) % v:size(2) + 1
end

function generate_beam(model, initial, K, max_sent_l, source)
  --reset decoder initial states
  local n = max_sent_l
  -- Backpointer table.
  local prev_ks = torch.LongTensor(n, K):fill(1)
  -- Current States.
  local next_ys = torch.LongTensor(n, K):fill(1)
  -- Current Scores.
  local scores = torch.FloatTensor(n, K)
  local context_vec
  scores:zero()
  local source_l = math.min(source:size(1), opt.max_sent_l)
  local attn_argmax = {} -- store attn weights
  attn_argmax[1] = {}

  local states = {} -- store predicted word idx
  states[1] = {}
  for k = 1, 1 do
    table.insert(states[1], initial)
    table.insert(attn_argmax[1], initial)
    next_ys[1][k] = State.next(initial)
  end

  local source_input
  if model_opt.use_chars_enc == 1 then
    source_input = source:view(source_l, 1, source:size(2)):contiguous()
  else
    source_input = source:view(source_l, 1)
  end

  local rnn_state_enc = {}
  for i = 1, #init_fwd_enc do
    table.insert(rnn_state_enc, init_fwd_enc[i]:zero())
  end
  local context = context_proto[{{}, {1,source_l}}]:clone() -- 1 x source_l x rnn_size

  for t = 1, source_l do
    local encoder_input = {source_input[t], table.unpack(rnn_state_enc)}
    local out = model[1]:forward(encoder_input)
    rnn_state_enc = out
    context[{{},t}]:copy(out[#out])
    if t == source_l then
      context_vec = out[#out]
    end
  end
  local pred 
  if opt.vector == 0 then
    pred = model[2]:forward(context_vec)
  end
  if opt.vector == 0 then
    return pred
  else
    return context_vec
  end
end

function idx2key(file)
  local f = io.open(file,'r')
  local t = {}
  for line in f:lines() do
    local c = {}
    for w in line:gmatch'([^%s]+)' do
      table.insert(c, w)
    end
    t[tonumber(c[2])] = c[1]
  end
  return t
end

function flip_table(u)
  local t = {}
  for key, value in pairs(u) do
    t[value] = key
  end
  return t
end

function get_layer(layer)
  if layer.name ~= nil then
    if layer.name == 'decoder_attn' then
      decoder_attn = layer
    elseif layer.name:sub(1,3) == 'hop' then
      hop_attn = layer
    elseif layer.name:sub(1,7) == 'softmax' then
      table.insert(softmax_layers, layer)
    elseif layer.name == 'word_vecs_enc' then
      word_vecs_enc = layer
    elseif layer.name == 'word_vecs_dec' then
      word_vecs_dec = layer
    end
  end
end

function sent2wordidx(sent, word2idx, start_symbol)
  local t = {}
  local u = {}
  if start_symbol == 1 then
    table.insert(t, START)
    table.insert(u, START_WORD)
  end

  for word in sent:gmatch'([^%s]+)' do
    local idx = word2idx[word] or UNK
    table.insert(t, idx)
    table.insert(u, word)
  end
  if start_symbol == 1 then
    table.insert(t, END)
    table.insert(u, END_WORD)
  end
  return torch.LongTensor(t), u
end

function sent2charidx(sent, char2idx, max_word_l, start_symbol)
  local words = {}
  if start_symbol == 1 then
    table.insert(words, START_WORD)
  end
  for word in sent:gmatch'([^%s]+)' do
    table.insert(words, word)
  end
  if start_symbol == 1 then
    table.insert(words, END_WORD)
  end
  local chars = torch.ones(#words, max_word_l)
  for i = 1, #words do
    chars[i] = word2charidx(words[i], char2idx, max_word_l, chars[i])
  end
  return chars, words
end

function word2charidx(word, char2idx, max_word_l, t)
  t[1] = START
  local i = 2
  for _, char in utf8.next, word do
    char = utf8.char(char)
    local char_idx = char2idx[char] or UNK
    t[i] = char_idx
    i = i+1
    if i >= max_word_l then
      t[i] = END
      break
    end
  end
  if i < max_word_l then
    t[i] = END
  end
  return t
end

function wordidx2sent(sent, idx2word, source_str, attn, skip_end)
  local t = {}
  local start_i, end_i
  skip_end = skip_start_end or true
  if skip_end then
    end_i = #sent-1
  else
    end_i = #sent
  end
  for i = 2, end_i do -- skip START and END
    if sent[i] == UNK then
      if opt.replace_unk == 1 then
        local s = source_str[attn[i]]
        if phrase_table[s] ~= nil then
          print(s .. ':' ..phrase_table[s])
        end
        local r = phrase_table[s] or s
        table.insert(t, r)
      else
        table.insert(t, idx2word[sent[i]])
      end
    else
      table.insert(t, idx2word[sent[i]])
    end
  end
  return table.concat(t, ' ')
end

function keywordvec2word(vec, idx2keyword, n)
  local t = {}
  vec_sort, order = torch.sort(vec,2,true)
  for i = 1, n do
    if idx2keyword[order[1][i]] ~= nil then
    table.insert(t, idx2keyword[order[1][i]])
    table.insert(t,vec_sort[1][i])
    end
  end
  return table.concat(t, ' ')
end

function clean_sent(sent)
  local s = stringx.replace(sent, UNK_WORD, '')
  s = stringx.replace(s, START_WORD, '')
  s = stringx.replace(s, END_WORD, '')
  s = stringx.replace(s, START_CHAR, '')
  s = stringx.replace(s, END_CHAR, '')
  return s
end

function strip(s)
  return s:gsub("^%s+",""):gsub("%s+$","")
end


function main()
  -- parse input params
  opt = cmd:parse(arg)

  -- some globals
  PAD = 1; UNK = 2; START = 3; END = 4
  PAD_WORD = '<blank>'; UNK_WORD = '<unk>'; START_WORD = '<s>'; END_WORD = '</s>'
  START_CHAR = '{'; END_CHAR = '}'
  MAX_SENT_L = opt.max_sent_l
  assert(path.exists(opt.src_file), 'src_file does not exist')
  assert(path.exists(opt.model), 'model does not exist')

  if path.exists(opt.targ_file) then
    targ_sents = {}
    local file = io.open(opt.targ_file, 'r')
    for line in file:lines() do
      table.insert(targ_sents, line)
    end
  end
  if opt.gpuid >= 0 then
    require 'cutorch'
    require 'cunn'
    if opt.cudnn == 1 then
      require 'cudnn'
    end
  end
  print('loading ' .. opt.model .. '...')
  checkpoint = torch.load(opt.model)
  print('done!')

  -- load model and word2idx/idx2word dictionaries
  model, model_opt = checkpoint[1], checkpoint[2]
  print(#model) 
  for i = 1, #model do
    model[i]:evaluate()
  end


  -- for backward compatibility
  model_opt.brnn = model_opt.brnn or 0
  model_opt.input_feed = model_opt.input_feed or 1
  model_opt.attn = model_opt.attn or 0

  idx2word_src = idx2key(opt.src_dict)
  word2idx_src = flip_table(idx2word_src)
  idx2word_targ = idx2key(opt.targ_dict)
  word2idx_targ = flip_table(idx2word_targ)
  if opt.vector == 0 then
    idx2keyword = idx2key(opt.keyword_dict)
  end

  if opt.gpuid >= 0 then
    cutorch.setDevice(opt.gpuid)
    for i = 1, #model do
      model[i]:double():cuda()
      model[i]:evaluate()
    end
  end
  softmax_layers = {}
  model[2]:apply(get_layer)
  context_proto = torch.zeros(1, MAX_SENT_L, model_opt.rnn_size)
  local h_init_enc = torch.zeros(opt.beam, model_opt.rnn_size)
  if opt.gpuid >= 0 then
    h_init_enc = h_init_enc:cuda()
    cutorch.setDevice(opt.gpuid)
    context_proto = context_proto:cuda()
  end
  init_fwd_enc = {}
  for L = 1, model_opt.num_layers do
    table.insert(init_fwd_enc, h_init_enc:clone())-- memory cell
    table.insert(init_fwd_enc, h_init_enc:clone())-- hidden state
  end
  State = StateAll
  local sent_id = 0
  pred_sents = {}
  local file = io.open(opt.src_file, "r")
  local out_file = io.open(opt.output_file,'w')
  local vector_file 
  if opt.vector == 1 then
    vector_file= io.open(opt.vector_file,"w")
  end
  local context_vec_out

  for line in file:lines() do
    sent_id = sent_id + 1
    line = clean_sent(line)
    
    print('SENT ' .. sent_id .. ': ' ..line)
    source, source_str = sent2wordidx(line, word2idx_src, model_opt.start_symbol)
    state = State.initial(START)
    local context_vec_tmp
    local pred_vec
    if opt.vector == 1 then
      context_vec_tmp = generate_beam(model, state, opt.beam, MAX_SENT_L, source)
      if sent_id == 1 then
        context_vec_out = context_vec_tmp
      else
        context_vec_out = torch.cat(context_vec_out, context_vec_tmp, 1)
      end
    else
      pred_vec = generate_beam(model, state, opt.beam, MAX_SENT_L, source)
      keywords = keywordvec2word(pred_vec, idx2keyword, 10)
      out_file:write(line..'\n')
      out_file:write(targ_sents[sent_id]..'\n')
      out_file:write(keywords..'\n\n')
      print(keywords)
    end
  end
  if opt.vector == 1 then 
    splitter = ","

    for i=1,context_vec_out:size(1) do
        for j=1,context_vec_out:size(2) do
            vector_file:write(context_vec_out[i][j])
            if j == context_vec_out:size(2) then
                vector_file:write("\n")
            else
                vector_file:write(splitter)
            end
        end
    end
    vector_file:close()
  end
  out_file:close()
end

main()
