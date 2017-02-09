-- Update dimension references to account for intermediate supervision
ref.predDim = {dataset.nParts,5}
ref.outputDim = {}
criterion = nn.ParallelCriterion()
for i = 1,opt.nStack do
    ref.outputDim[i] = {dataset.nParts, opt.outputRes, opt.outputRes}
    criterion:add(nn[opt.crit .. 'Criterion']())
end

-- Function for data augmentation, randomly samples on a normal distribution
local function rnd(x) return math.max(-2*x,math.min(2*x,torch.randn(1)[1]*x)) end

-- Code to generate training samples from raw images
function generateSample(set, idx)
    local img = dataset:loadImage(idx)
    local bbox = dataset:getBoundingBox(idx)
    local label_ = dataset:getLabel(idx)

    label = torch.Tensor(dataset.nParts, label_:size()[1], label_:size()[2]):zero()

    for i = 1,dataset.nParts do
        label[i][label_:eq(i)] = 1
    end

    inp = image.crop(img, bbox[1], bbox[2], bbox[3], bbox[4])
    out = image.crop(label, bbox[1], bbox[2], bbox[3], bbox[4])
    inp = image.scale(inp, opt.inputRes..'x'..opt.inputRes)
    out = image.scale(out, opt.outputRes..'x'..opt.outputRes)

    if set == 'train' then
        -- Flipping and color augmentation
        if torch.uniform() < .5 then
            inp = flip(inp)
            out = shuffleLR(flip(out))
        end
        inp[1]:mul(torch.uniform(0.6,1.4)):clamp(0,1)
        inp[2]:mul(torch.uniform(0.6,1.4)):clamp(0,1)
        inp[3]:mul(torch.uniform(0.6,1.4)):clamp(0,1)
    end

    return inp,out
end

-- Load in a mini-batch of data
function loadData(set, idxs)
    if type(idxs) == 'table' then idxs = torch.Tensor(idxs) end
    local nsamples = idxs:size(1)
    local input,label

    for i = 1,nsamples do
        local tmpInput,tmpLabel
        tmpInput,tmpLabel = generateSample(set, idxs[i])
        tmpInput = tmpInput:view(1,unpack(tmpInput:size():totable()))
        tmpLabel = tmpLabel:view(1,unpack(tmpLabel:size():totable()))
        if not input then
            input = tmpInput
            label = tmpLabel
        else
            input = input:cat(tmpInput,1)
            label = label:cat(tmpLabel,1)
        end
    end

    if opt.nStack > 1 then
        -- Set up label for intermediate supervision
        local newLabel = {}
        for i = 1,opt.nStack do newLabel[i] = label end
        return input,newLabel
    else
        return input,label
    end
end

function postprocess(set, idx, output)
    local tmpOutput
    if type(output) == 'table' then tmpOutput = output[#output]
    else tmpOutput = output end
    local p = getPreds(tmpOutput)
    local scores = torch.zeros(p:size(1),p:size(2),1)

    -- Very simple post-processing step to improve performance at tight PCK thresholds
    for i = 1,p:size(1) do
        for j = 1,p:size(2) do
            local hm = tmpOutput[i][j]
            local pX,pY = p[i][j][1], p[i][j][2]
            scores[i][j] = hm[pY][pX]
            if pX > 1 and pX < opt.outputRes and pY > 1 and pY < opt.outputRes then
               local diff = torch.Tensor({hm[pY][pX+1]-hm[pY][pX-1], hm[pY+1][pX]-hm[pY-1][pX]})
               p[i][j]:add(diff:sign():mul(.25))
            end
        end
    end
    p:add(0.5)

    -- Transform predictions back to original coordinate space
    local p_tf = torch.zeros(p:size())
    for i = 1,p:size(1) do
        _,c,s = dataset:getPartInfo(idx[i])
        p_tf[i]:copy(transformPreds(p[i], c, s, opt.outputRes))
    end

    return p_tf:cat(p,3):cat(scores,3)
end

function accuracy_(output, label)
    local total = output:numel()
    local correct = 0
    for i=1,output:size()[1] do
      for j=1,dataset.nParts do
        local a=output[i][j]:gt(0)
        local b=label[i][j]:gt(0.5)
        --print(a:size())
        --print(b:size())
        local sum = a:eq(b):sum()
        correct = correct + sum
      end
    end
    return correct/total
end

function accuracy(output,label)
    if type(output) == 'table' then
        return accuracy_(output[#output],label[#output])
    else
        return accuracy_(output,label)
    end
end