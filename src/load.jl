using Ghost
using Ghost: Tape, Input, mkcall, Variable, V
using NNlib


struct ONNXCtx
    name2var::Dict{String, Variable}
    default_val::Union{Missing, Nothing}
end

ONNXCtx(;exec=true) = ONNXCtx(Dict(), exec ? missing : nothing)

# TODO: implement rebind_context!()

###############################################################################
#                               Operations                                    #
###############################################################################


mrev(x) = x
mrev(x::AbstractVector) = reverse(x)
prev(x) = x
prev(x::AbstractVector) = reshape(permutedims(reverse(reshape(x, length(x) ÷ 2,:);dims=1)),:)


# mrev = maybe reverse. prev = rearrange padding, e.g. (1,2,1,2) => (2,2,1,1) or (1,2,3,1,2,3) => (3,3,2,2,1,1)
_akpsd(params) = get(params, :activation, identity), mrev(get(params, :kernel_shape, 1)), prev(get(params, :pads, 0)), mrev(get(params, :strides, 1)), mrev(get(params, :dilations, 1))
akpsd(params) = a2t.(_akpsd(params))
a2t(x) = x
a2t(a::AbstractArray) = Tuple(a)



# const OPS = Dict{Symbol, Any}()

# OPS[:Conv] = function(params, weight::AbstractArray{T, N}, bias=Flux.Zeros()) where {T, N}
#     a,_,p,s,d = akpsd(params)
#     @assert get(params, :group, 1) == 1 "Group size not supported!" #Or?
#     return Conv(flipweights(FluxConv{N-2}(), weight), bias, a, pad=p, stride=s, dilation=d)
# end


load_node!(tape::Tape, nd::NodeProto) = load_node!(tape, nd, Val(Symbol(nd.op_type)))

function load_node!(tape::Tape, nd::NodeProto, ::Val{:Conv})
    attrs = Dict(nd.attribute)
    _,_,p,s,d = akpsd(attrs)
    kw = (stride = s, pad = p, dilation = d, groups = get(attrs, "group", 1))
    # positional arguments
    x, w, b = [tape.c.name2var[name] for name in nd.input]
    # record conv
    kwconv = Core.kwfunc(NNlib.conv)
    c = push!(tape, mkcall(kwconv, kw, NNlib.conv, x, w; val=tape.c.default_val))
    # record bias addition
    bias_size = (ntuple(_ -> 1, length(s))..., :, 1)
    br = push!(tape, mkcall(reshape, b, bias_size; val=tape.c.default_val))
    r = push!(tape, mkcall(broadcast, +, c, br; val=tape.c.default_val))
    # update name mapping
    tape.c.name2var[nd.output[1]] = r
end

function load_node!(tape::Tape, nd::NodeProto, ::Val{OP}) where OP
    @warn "add_node!() is not implemented for op_type = $OP, adding dummy operation instead"
    args = [tape.c.name2var[name] for name in nd.input]
    r = push!(tape, mkcall(identity, args[1]))
    tape.c.name2var[nd.output[1]] = r
end


###############################################################################
#                                    API                                      #
###############################################################################


function load(filename::AbstractString, args...; exec::Bool=true)
    onnx_model = open(filename) do io
        readproto(io, ModelProto())
    end;
    g = onnx_model.graph;
    tape = Tape(ONNXCtx(; exec=exec))
    # create map of initializers
    init_vals = Dict{String, Any}()
    for init in g.initializer
        # TODO: consider non-array inputs
        init_vals[init.name] = array(init)
    end
    # load inputs
    arg_idx = 1
    for inp in g.input
        val = get(init_vals, inp.name, missing)
        if val === missing && exec == true
            val = args[arg_idx]
            arg_idx += 1
        end
        v = push!(tape, Input(val))
        tape.c.name2var[inp.name] = v
    end
    # load nodes
    for nd in g.node
        load_node!(tape, nd)
    end
    return tape
end