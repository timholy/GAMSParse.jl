module GAMSParse

using DataStructures, OffsetArrays
using Compat

export parsegams

include("types.jl")
include("consts.jl")
include("io.jl")
include("lexer.jl")
include("parser.jl")

"""
    modex = parsegams(Module, modname, gams)
    modex = parsegams(Module, filename)

Return an expression defining a module which, when evaluated (`mod = eval(modex)`),
contains a (non-exported) function `f(x)` evaluating the objective function defined in the
corresponding GAMS file.
"""
function parsegams(::Type{Module}, modname::Symbol, gams::Dict{String,Any})
    sets = parsesets(gams)
    vars = allvars(gams)
    consts, constexs = parseconsts(gams, sets, vars)
    # Create the computational part of the function body
    eqex = Expr[]
    varops = Dict{Symbol,Symbol}()  # for initialization of sentinel values
    for (eqname, eqstr) in gams["Equations"]
        if iscallstr(eqname)
            ex, _ = parse(eqname, 1)
            parsedeq, setvar, op = parseassign(eqstr, vars; loop=map(sym->(sym, sets[sym]), ex.args[2:end]))
        else
            parsedeq, setvar, op = parseassign(eqstr, vars)
        end
        if op != :(=)
            varops[setvar] = op
            parsedeq = replace_constr_with_minmax!(parsedeq)
        end
        push!(eqex, parsedeq)
    end
    # Create the return statement
    retvalstr = gams["minimizing"]
    push!(eqex, :(return $(Symbol(retvalstr))))
    # As needed, destructure the input vector
    varstrings = copy(gams["Variables"])
    i = findfirst(equalto(retvalstr), varstrings)
    if i > 0
        deleteat!(varstrings, i)
    end
    for j = 2:length(varstrings)
        ex, _ = parse(varstrings[j], 1)
        if ex isa Symbol
            if haskey(varops, ex)
                varinit = sentinelval[varops[ex]]
                unshift!(eqex, :($ex = $varinit))
            end
            continue
        end
        @assert(ex.head == :call)
        varsym, indexsym = ex.args[1], (ex.args[2:end]...)
        r = map(x->sets[x], indexsym)
        dims = map(last, r)
        # sentinel initialization
        if haskey(varops, varsym)
            varinit = sentinelval[varops[varsym]]
            unshift!(eqex, :(fill!($varsym, $varinit)))
        end
        unshift!(eqex, :($varsym = Array{Float64}(uninitialized, $dims)))
    end
    if !iscallstr(varstrings[1])
        xin = gensym("x")
        unshift!(eqex, Expr(:(=), Expr(:tuple, Symbol.(varstrings)...), xin))
    else
        xin = varsym(varstrings[1])
    end
    body = Expr(:block, eqex...)
    # Set up the constant expressions
    constexprs = Expr[]
    for (k, v) in consts
        push!(constexprs, Expr(:const, :($k = $v)))
    end
    append!(constexprs, constexs)
    modex = quote
        module $modname
        using Compat
        $gamsfuncs
        $(Expr(:block, constexprs...))
        function f($xin)
            $body
        end
        end  # module
    end
    return Expr(:toplevel, modex.args[2])
end
function parsegams(::Type{Module}, filename::AbstractString, gams::Dict{String,Any})
    bname, _ = splitext(basename(filename))
    return parsegams(Module, Symbol(bname), gams)
end
function parsegams(::Type{Module}, filename::AbstractString)
    gams = parsegams(filename)
    bname, _ = splitext(basename(filename))
    return parsegams(Module, Symbol(bname), gams)
end

function getaxes(setnames, sets)
    axs = []
    for name in setnames
        s = sets[string(name)]
        push!(axs, s isa UnitRange ? s : Base.OneTo(length(s)))
    end
    (axs...,)
end

# function varsplit(name::AbstractString)
#     m = match(r"([a-zA-Z0-9]+)\((.*)\)", name)
#     m == nothing && return (name, String[])
#     return (m.captures[1], strip.(split(m.captures[2], ',')))
# end

# function varinfo(name, attr, sets)
#     name, axnames = varsplit(name)
#     isempty(axnames) && return name=>VarInfo(attr, ())
#     return name=>VarInfo(attr, getaxes(axnames, sets))
# end

# function varinfo(name, attr, ::Type{Float64})
#     basename, axnames = varsplit(name)
#     isempty(axnames) && return basename=>VarInfo(attr, ())
#     error("must have sets for variable style ", name)
# end

function allocate(setnames, sets)
    axs = getaxes(setnames, sets)
    axs isa Tuple{} && return 0.0
    axs isa Tuple{Base.OneTo{Int},Vararg{Base.OneTo{Int}}} &&
        return Array{Float64}(uninitialized, length.(axs))
    return OffsetArray{Float64}(uninitialized, axs)
end

function parseparameters!(dest, rest)
    m = match(r"=", rest)
    if m === nothing
        sym, vals = splitws(rest)
        if isempty(vals)
            # This is a "size" declaration
            dest[sym] = ""
        else
            if !isempty(vals) && vals[1] == vals[end] == '/'
                vals = strip(vals[2:end-1])
            end
            if !isempty(vals)
                dest[sym] = vals
            end
        end
    else
        lhs, rhs = strip(rest[1:m.offset-1]), strip(rest[m.offset+1:end])
        dest[lhs] = rhs
    end
    return dest
end

function splitws(str; rmsemicolon::Bool=false)
    iend = endof(str)
    if rmsemicolon && str[iend] == ';'
        iend = prevind(str, iend)
    end
    m = match(r"\s", str)
    m == nothing && return str, ""
    return str[1:m.offset-1], strip(str[m.offset:iend])
end

function varsym(str::AbstractString)
    ex, _ = parse(str, 1)
    ex isa Symbol && return ex
    if ex isa Expr && (ex.head == :call || ex.head == :ref)
        return ex.args[1]
    end
    error(str, " does not appear to refer to a variable")
end

iscallstr(str) = match(r"\(.*\)", str) != nothing
function callsym(str)
    local ex
    try
        ex = parse(str)
    catch
        error("couldn't parse ", str)
    end
    ex isa Symbol && return ex
    ex isa Expr || return nothing
    if ex.head == :call
        cstr = string(ex.args[1])
        # GAMS variables must start with a letter and can only contain letters and numbers
        match(r"^[a-zA-Z][a-zA-Z0-9]*$", cstr) != nothing && return ex.args[1]
    end
    return nothing
end

function allvars(gams::Dict)
    vars = Set{Symbol}()
    for v in gams["Variables"]
        push!(vars, GAMSParse.varsym(v))
    end
    if haskey(gams, "Table")
        for (k,v) in gams["Table"]
            push!(vars, GAMSParse.varsym(k))
        end
    end
    if haskey(gams, "Parameters")
        for (k,v) in gams["Parameters"]
            push!(vars, GAMSParse.varsym(k))
        end
    end
    return vars
end

function parsesets(gams::Dict)
    sets = Dict{Symbol,UnitRange{Int}}()
    haskey(gams, "Sets") || return sets
    for (sym, rstr) in gams["Sets"]
        # We require these to be of the form `sym  /1*n/`
        rex, _ = parse(rstr[2:end-1], 1)
        if rex.head == :call && rex.args[1] == :* && length(rex.args) == 3 &&
                isa(rex.args[2], Integer) && isa(rex.args[3], Integer)
            a, b = rex.args[2], rex.args[3]
            sets[Symbol(sym)] = a == 1 ? Base.OneTo(b) : (a:b)
        else
            error("failed to parse set assignment ", rstr)
        end
    end
    return sets
end

function parseconsts(gams::Dict, sets::Dict{Symbol,UnitRange{Int}}, vars)
    consts, exprs = Dict{Symbol,Any}(), Expr[]
    for fn = ("Parameters", "Scalars")
        if haskey(gams, fn)
            for (varstr, val) in gams[fn]
                varex, _ = parse(varstr, 1)
                if varex isa Symbol
                    consts[varex] = parse(val)
                    continue
                end
                @assert(varex.head == :call)
                varsym, indexsym = varex.args[1], (varex.args[2:end]...)
                if indexsym isa Tuple{Symbol,Vararg{Symbol}}
                    r = map(x->sets[x], indexsym)
                    dims = map(last, r)
                    if val == ""
                        # Allocation only
                        consts[varsym] = Array{Float64}(uninitialized, dims)
                    else
                        lines = split(val, '\n')
                        if length(lines) == prod(length.(r))
                            c = haskey(consts, varsym) ? consts[varsym] : Array{Float64}(uninitialized, dims)
                            for line in lines
                                istr, cstr = splitws(strip(line))
                                c[numeval(istr)] = numeval(cstr)
                            end
                            consts[varsym] = c
                        else
                            # The expression must be a formula for varsym
                            push!(exprs, :(const $varsym = Array{Float64}(uninitialized, $dims)))
                            lhs, rhs = calls2refs(varstr, vars), calls2refs(val, vars)
                            body = Expr(:(=), lhs, rhs)
                            while !isempty(indexsym)
                                thissym, thisr = indexsym[1], r[1]
                                body = quote
                                    for $thissym in $thisr
                                        $body
                                    end
                                end
                                indexsym, r = Base.tail(indexsym), Base.tail(r)
                            end
                            push!(exprs, body)
                            # Also add to list of variables
                            push!(vars, varsym)
                        end
                    end
                elseif indexsym isa Tuple{Integer,Vararg{Integer}}
                    c = consts[varsym]
                    if isnumberstring(val)
                        c[indexsym...] = numeval(val)
                    else
                        varex = calls2refs!(varex, vars)
                        rhs = calls2refs!(parse(val), vars)
                        if rhs.head == :ref && all(x->isa(x, Number), rhs.args[2:end])
                            rc = consts[rhs.args[1]]
                            c[indexsym...] = rc[rhs.args[2:end]...]
                        else
                            push!(exprs, :($varex = $rhs))
                        end
                    end
                end
            end
        end
    end
    if haskey(gams, "Table")
        for (varstr, val) in gams["Table"]
            varex, _ = parse(varstr, 1)
            @assert(varex.head == :call)
            varsym, indexsym = varex.args[1], (varex.args[2:end]...)
            r = map(x->sets[x], indexsym)
            dims = map(last, r)
            c = Array{Float64}(uninitialized, dims)
            lines = strip.(split(val, '\n'))
            next_is_header = true
            @assert(length(r) == 2)  # need to see an example before generalizing what follows
            colindex = 0:0
            for line in lines
                if isempty(line)
                    next_is_header = true
                elseif next_is_header || line[1] == '+'
                    if line[1] == '+'
                        line = line[2:end]
                    end
                    inds = split(line)
                    colindex = numeval(inds[1]):numeval(inds[end])
                    next_is_header = false
                else
                    rowvals = strip.(split(line, r"[\s-]", keep=false))
                    c[numeval(rowvals[1]), colindex] = numeval.(rowvals[2:end])
                end
            end
            consts[varsym] = c
        end
    end
    return consts, exprs
end

function numeval(str)
    m = match(r"\.", str)
    return m == nothing ? parse(Int, str) : parse(Float64, str)
end

function isnumberstring(str)
    m = match(r"^[+-]?[0-9]*\.?[0-9]*([eE][+-]?[0-9]*)?$", str)
    return m !== nothing
end

function calls2refs!(ex::Expr, vars)
    for i = 1:length(ex.args)
        ex.args[i] = calls2refs!(ex.args[i], vars)
    end
    if ex.head == :call && ex.args[1] ∈ vars
        return Expr(:ref, ex.args...)
    end
    return ex
end
calls2refs!(ex, vars) = ex
function calls2refs(str::AbstractString, vars)
    ex, _ = parse(str, 1)
    return calls2refs!(ex, vars)
end

function parseassign(eqex, vars; loop=nothing)
    if endswith(eqex, ';')
        eqex = eqex[1:end-1]
    end
    m = match(r"=([eEgGlL])=", eqex)
    m === nothing && error("cannot parse ", eqex)
    @assert(length(m.captures) == 1)
    op = eqops[m.captures[1]]
    if op == :(=)
        exhead = op
        exargs = ()
    else
        exhead = :call
        exargs = (op,)
    end
    lhs, rhs = strip(eqex[1:m.offset-1]), strip(eqex[m.offset+3:end])
    lhssym, rhssym = callsym(lhs), callsym(rhs)
    lhs, rhs = replaceexprs(lhs, vars), replaceexprs(rhs, vars)
    if rhssym ∈ vars || isnumberstring(lhs)
        lhs, rhs = rhs, lhs
        lhssym, rhssym = rhssym, lhssym
    end
    local body
    if lhssym ∈ vars
        lhsex, rhsex = parse(lhs), parse(rhs)
        body = Expr(exhead, exargs..., lhsex, rhsex)
        if loop != nothing
            while !isempty(loop)
                loopvar, loopr = loop[1]
                body = quote
                    for $loopvar = $loopr
                        $body
                    end
                end
                shift!(loop)
            end
        end
    elseif isnumberstring(rhs)
        # Assume the variable-to-be-assigned is last
        i = endof(lhs)
        while !isspace(lhs[i]) && i > 0
            i = prevind(lhs, i)
        end
        @assert(i>0)
        vstr = lhs[nextind(lhs, i):end]
        lhssym = varsym(vstr)
        @assert(lhssym ∈ vars)
        # Find the preceding operator
        while i > 0 && ((c = lhs[i]) != '+' && c != '-')
            i = prevind(lhs, i)
        end
        @assert(i>0)
        c = lhs[i] == '+' ? -1 : 1
        rest = lhs[1:i-1]
        restex = parse(rest)
        rhsval = numeval(rhs)
        body = Expr(exhead, exargs..., parse(vstr), :($c * $restex + $rhsval))
        if loop != nothing
            while !isempty(loop)
                loopvar, loopr = loop[1]
                body = quote
                    for $loopvar = $loopr
                        $body
                    end
                end
                shift!(loop)
            end
        end
    else
        error("neither the lhs $lhs nor rhs $rhs appeared in $vars")
    end
    return body, lhssym, op
end

function replaceexprs(str, vars)
    ex, _ = parse(str, 1)
    newex = replaceexprs!(ex)
    finalex = calls2refs!(newex, vars)
    string(finalex)
end

function replace_charints(str)
    # Replace 'i' (where i is an integer) with the integer
    return replace(str, r"'(\d*)'", s"\1")
end

function replace_pow(str)
    # Replace "**" -> "^"
    return replace(str, r"\*\*", s"^")
end

function replace_logical(str)
    str = replace(str, r" and ", s" & ")
    str = replace(str, r" or ", s" | ")
    return str
end

function replaceexprs!(ex::Expr)
    if ex.head == :call && ex.args[1] ∈ (:smax, :sum)
        vars, val = ex.args[2], replaceexprs!(ex.args[3])
        index_exprs = Expr[]
        if vars isa Symbol
            sym, slot, success = find_index_usage(val, vars)
            success || error("could not find $vars in $val")
            push!(index_exprs, :($vars in Compat.axes($sym, $slot)))
        else
            for v in vars
                sym, slot, success = find_index_usage(val, v)
                success || error("could not find $v in $val")
                push!(index_exprs, :($v in Compat.axes($sym, $slot)))
            end
        end
        return Expr(:call, gamsf2jf[ex.args[1]], Expr(:comprehension, Expr(:generator, val, index_exprs...)))
    end
    for i = 1:length(ex.args)
        ex.args[i] = replaceexprs!(ex.args[i])
    end
    return ex
end
replaceexprs!(ex) = ex

function getdefault!(gams, tag, ::Type{T}) where T
    if !haskey(gams, tag)
        gams[tag] = T<:Dict ? T() : (T<:Vector ? T(uninitialized, 0) : error("type $T not handled"))
    end
    return gams[tag]
end
getdefault!(gams, tag) = getdefault!(gams, tag, Dict{String,String})

## Converting =g= and =l= (> and <) "constraints" into min/max statements
const sentinelval = Dict(:> => -Inf, :< => Inf)

function replace_constr_with_minmax!(ex::Expr)
    if ex.head == :call && length(ex.args) == 3
        if ex.args[1] == :>
            return Expr(:(=), ex.args[2], Expr(:call, :max, ex.args[2], ex.args[3]))
        elseif ex.args[1] == :<
            return Expr(:(=), ex.args[2], Expr(:call, :min, ex.args[2], ex.args[3]))
        end
    end
    for i = 1:length(ex.args)
        ex.args[i] = replace_constr_with_minmax!(ex.args[i])
    end
    return ex
end
replace_constr_with_minmax!(arg) = arg

function find_index_usage(ex::Expr, indexsym)
    if ex.head == :call
        i = findfirst(ex.args, indexsym)
        if i > 0
            return ex.args[1], i-1, true
        end
    end
    for arg in ex.args
        sym, slot, success = find_index_usage(arg, indexsym)
        success && return sym, slot, success
    end
    return :missing, 0, false
end
find_index_usage(ex, indexsym) = :missing, 0, false

end # module
