using BSON

rawproto(io::IO) = readproto(io, Proto.ModelProto())
rawproto(path::String) = open(rawproto, path)

"""
Retrieve only the useful information from a AttributeProto
object into a Dict format.
"""
function convert_model(x::Proto.AttributeProto)
  field = [:f, :i, :s, :t, :g, :floats, :ints, :strings, :tensors, :graphs][x._type]
  Symbol(x.name) => getfield(x, field)
end

convert_array(as) = Dict(convert_model(a) for a in as)

"""
Convert a ValueInfoProto to  ValueInfo.
"""
function convert_model(model::Proto.ValueInfoProto)
    a = Types.ValueInfo(model.name, model.doc_string)
    return a 
end

"""
Convert an OperatorSetIdProto to Dict.
"""
function convert_model(model::ONNX.Proto.OperatorSetIdProto)
    a = Dict{Symbol, Any}()
    fields = [:domain, :version]
    for ele in fields
        a[ele] = getfield(model, ele)
    end
    return a
end

"""
Convert a StringStringEntryProto to Dict.
"""
function convert_model(model::ONNX.Proto.StringStringEntryProto)
    a = Dict{Symbol, Any}()
    fields = [:key, :value]
    for ele in fields
        a[ele] = getfield(model, ele)
    end
    return a
end

"""
Get the array from a TensorProto object.
"""
function get_array(x::Proto.TensorProto)
  @assert x.data_type == 1 # Float32
  x = reshape(reinterpret(Float32, x.raw_data), x.dims...)
  return permutedims(x, reverse(1:ndims(x)))
end

"""
Convert a ModelProto object to a Model type.
"""
function convert(model::Proto.ModelProto)
    # conversion for opset_import
    arr1 = Array{Any, 1}()
    for ele in model.opset_import
        push!(arr1, convert_model(ele))
    end

    # conversion for stringstringentry proto
    arr2 = Array{Any, 1}()
    for ele in model.metadata_props
        push!(arr2, convert_model(ele))
    end

    m = Types.Model(model.ir_version,
                arr1, model.producer_name,
                model.producer_version,
                model.domain, model.model_version, 
                model.doc_string, convert(model.graph),
                arr2)
    return m
end

"""
Convert a GraphProto object to Graph type.
"""
function convert(model::Proto.GraphProto)
    # conversion for vector of nodeproto
    arr1 = Array{Any, 1}()
    for ele in model.node
        push!(arr1, convert(ele))
    end

    # conversion for vector of tensorproto
    arr2 = Dict{Any, Any}()
    for ele in model.initializer
        arr2[ele.name] = get_array(ele)
    end

    #conversion for vector of valueinfoproto
    arr3 = Array{Types.ValueInfo ,1}()
    for ele in model.input
        push!(arr3, convert_model(ele))
    end

    arr4 = Array{Types.ValueInfo ,1}()
    for ele in model.output
        push!(arr4, convert_model(ele))
    end

    arr5 = Array{Types.ValueInfo ,1}()
    for ele in model.value_info
        push!(arr5, convert_model(ele))
    end

    m = Types.Graph(arr1,                       
            model.name, 
            arr2, model.doc_string, 
            arr3, arr4, arr5)
    return m
end

"""
Convert a Proto.NodeProto to Node type.
"""
function convert(model::Proto.NodeProto)
    # Conversion of attribute
    arr1 = convert_array(model.attribute)

    m = Types.Node(model.input, 
            model.output, 
            model.name, 
            model.op_type, 
            model.domain,
            arr1, 
            model.doc_string)
    return m
end

function parent(path)
    temp = split(path, "/")
    res = ""
    for element in temp
        if (element != temp[end])
            res = res * element * "/"
        end
    end
    return res
end

"""
Serialize the weights to a binary format and stores in the
weights.bson file.
"""
function write_weights(model)
    f = rawproto(model)
    g = convert(f.graph)
    temp = weights(g)
    weights_dict = Dict{Symbol, Any}()
    for ele in keys(temp)
        weights_dict[Symbol(ele)] = temp[ele]
    end
    if '/' in model
        cd(parent(model))
    end
    bson("weights.bson", weights_dict)
end

"""
Retrieve the dictionary form the binary file (String to Any).
format.
""" 
function load_weights(name)
    a = BSON.load(name)
    weights = Dict{String, Any}()
    for ele in keys(a)
        weights[string(ele)] = a[ele]
    end
    return weights
end

"""
Create the model.jl file and write the model to it.
"""
function write_julia_file(model_file)
    f = readproto(open(model_file), ONNX.Proto.ModelProto())
    data = ONNX.code(convert(f).graph)
    touch("model.jl")
    str1 = "softmax(a::AbstractArray) = reshape(Flux.softmax(reshape(a, size(a)[3])), 1, 1, size(a)[3], 1) \n"
    str = "maxpool(a,b,c,d) = Flux.maxpool(a, b, pad=c, stride=d) \n"
    open("model.jl","w") do file
        write(file, str1*str*string(data))
    end
end

"""
Create the two files from the model.pb file.
"""
function load_model(model)
    write_weights(model)
    write_julia_file(model)
    return nothing
end