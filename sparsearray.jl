struct SparseArray{T,N} <: AbstractArray{T,N}
    data::Dict{NTuple{N,Int64}, T}
    dims::NTuple{N,Int64}
    SparseArray{T,N}(data::Dict{NTuple{N,Int64}, T},dims::NTuple{N,Int64}) where {T,N} = new{T,N}(data,dims);
    function SparseArray{T,N}(::UndefInitializer, dims::NTuple{N,Int}) where {T,N}
        data = Dict{NTuple{N,Int64}, T}()
        return new{T,N}(data, dims)
    end
    function SparseArray{T}(::UndefInitializer, dims::NTuple{N,Int}) where {T,N}
        data = Dict{NTuple{N,Int64}, T}()
        return new{T,N}(data, dims)
    end
    function SparseArray(A::SparseArray{T,N}) where {T,N}
        new{T,N}(copy(A.data), A.dims)
    end
end
memsize(A::SparseArray) = memsize(A.data)+memsize(A.dims);
@inline function Base.getindex(A::SparseArray{T,N}, I::Vararg{Int,N}) where {T,N}
    @boundscheck checkbounds(A, I...)
    return get(A.data, I, zero(T))
end
@inline function Base.setindex!(A::SparseArray{T,N}, v, I::Vararg{Int,N}) where {T,N}
    @boundscheck checkbounds(A, I...)
    if v != zero(v)
        A.data[I] = v
    else
        delete!(A.data, I) # does not do anything if there was no key I
    end
    return v
end

function Array{T,N}(a::SparseArray{T,N}) where {T,N}
    d = fill(zero(T),a.dims...);
    for (k,v) in a.data
        d[k...] = v;
    end
    d
end
function SparseArray(a::Array{T,N}) where {T,N}
    d = SparseArray{T,N}(undef,size(a));
    for (i,v) in zip(CartesianIndices(a),a)
        if abs(v) > eps(abs(v))
            d[Tuple(i)...] = v
        end
    end
    d
end
Base.copy(A::SparseArray) = SparseArray(A)

Base.size(A::SparseArray) = A.dims

Base.similar(A::SparseArray, ::Type{S}, dims::Dims{N}) where {S,N} =
    SparseArray{S,N}(Dict{NTuple{N,Int64},S}(), dims)

# TODO: Basic arithmitic

# Vector space functions
#------------------------
function LinearAlgebra.lmul!(a::Number, d::SparseArray)
    lmul!(a, d.data.vals)
    # typical occupation in a dict is about 30% from experimental testing
    # the benefits of scaling all values (e.g. SIMD) largely outweight the extra work
    return d
end
function LinearAlgebra.rmul!(d::SparseArray, a::Number)
    rmul!(d.data.vals, a)
    return d
end
function LinearAlgebra.axpby!(α, x::SparseArray, β, y::SparseArray)
    lmul!(y, β)
    for (k, v) in x
        y[k] += α*v
    end
    return y
end
function LinearAlgebra.axpy!(α, x::SparseArray, y::SparseArray)
    for (k, v) in x
        y[k] += α*v
    end
    return y
end

function LinearAlgebra.norm(x::SparseArray, p::Real = 2)
    norm(Base.Generator(last, x.data), p)
end

function LinearAlgebra.dot(x::SparseArray, y::SparseArray)
    size(x) == size(y) || throw(DimensionMismatch("dot arguments have different size"))
    s = dot(zero(eltype(x)), zero(eltype(y)))
    if length(x.data) >= length(y.data)
        iter = keys(x.data)
    else
        iter = keys(y.data)
    end
    @inbounds for I in iter
        s += dot(x[I...], y[I...])
    end
    return s
end

# TensorOperations compatiblity
#-------------------------------
function add!(α, A::SparseArray{<:Any, N}, CA::Symbol,
                β, C::SparseArray{<:Any, N}, indCinA) where {N}

    (N == length(indCinA) && TupleTools.isperm(indCinA)) ||
        throw(IndexError("Invalid permutation of length $N: $indCinA"))
    size(C) == TupleTools.getindices(size(A), indCinA) ||
        throw(DimensionMismatch("non-matching sizes while adding arrays"))

    β == one(β) || LinearAlgebra.lmul!(β, C);
    for (kA, vA) in A.data
        kC = TupleTools.getindices(kA, indCinA)
        C[kC...] += α* (CA == :C ? conj(vA) : vA)
    end
    C
end

function trace!(α, A::SparseArray{<:Any, NA}, CA::Symbol, β, C::SparseArray{<:Any, NC},
        indCinA, cindA1, cindA2) where {NA,NC}

    NC == length(indCinA) ||
        throw(IndexError("Invalid selection of $NC out of $NA: $indCinA"))
    NA-NC == 2*length(cindA1) == 2*length(cindA2) ||
        throw(IndexError("invalid number of trace dimension"))
    pA = (indCinA..., cindA1..., cindA2...)
    TupleTools.isperm(pA) ||
        throw(IndexError("invalid permutation of length $(ndims(A)): $pA"))

    sizeA = size(A)
    sizeC = size(C)

    TupleTools.getindices(sizeA, cindA1) == TupleTools.getindices(sizeA, cindA2) ||
        throw(DimensionMismatch("non-matching trace sizes"))
    sizeC == TupleTools.getindices(sizeA, indCinA) ||
        throw(DimensionMismatch("non-matching sizes"))

    β == one(β) || LinearAlgebra.lmul!(β, C);

    for (kA, v) in A.data
        kAc1 = TupleTools.getindices(kA, cindA1)
        kAc2 = TupleTools.getindices(kA, cindA2)
        kAc1 == kAc2 || continue

        kC = TupleTools.getindices(kC, indCinA)
        C[kC...] += α * (CA == :C ? conj(v) : v)
    end
    return C
end

function contract!(α, A::SparseArray, CA::Symbol, B::SparseArray, CB::Symbol,
        β, C::SparseArray,
        oindA::IndexTuple, cindA::IndexTuple, oindB::IndexTuple, cindB::IndexTuple,
        indCinoAB::IndexTuple, syms::Union{Nothing, NTuple{3,Symbol}} = nothing)

    pA = (oindA...,cindA...)
    (length(pA) == ndims(A) && TupleTools.isperm(pA)) ||
        throw(IndexError("invalid permutation of length $(ndims(A)): $pA"))
    pB = (oindB...,cindB...)
    (length(pB) == ndims(B) && TupleTools.isperm(pB)) ||
        throw(IndexError("invalid permutation of length $(ndims(B)): $pB"))
    (length(oindA) + length(oindB) == ndims(C)) ||
        throw(IndexError("non-matching output indices in contraction"))
    (ndims(C) == length(indCinoAB) && isperm(indCinoAB)) ||
        throw(IndexError("invalid permutation of length $(ndims(C)): $indCinoAB"))

    sizeA = size(A)
    sizeB = size(B)
    sizeC = size(C)

    csizeA = TupleTools.getindices(sizeA, cindA)
    csizeB = TupleTools.getindices(sizeB, cindB)
    osizeA = TupleTools.getindices(sizeA, oindA)
    osizeB = TupleTools.getindices(sizeB, oindB)

    csizeA == csizeB ||
        throw(DimensionMismatch("non-matching sizes in contracted dimensions"))
    TupleTools.getindices((osizeA..., osizeB...), indCinoAB) == size(C) ||
        throw(DimensionMismatch("non-matching sizes in uncontracted dimensions"))

    β == one(β) || LinearAlgebra.lmul!(β, C);

    for (kA, vA) in A.data
        kAc = TupleTools.getindices(kA, cindA)
        kAo = TupleTools.getindices(kA, oindA)
        for (kB, vB) in B.data
            kBc = TupleTools.getindices(kB, cindB)
            kAc == kBc || continue

            kBo = TupleTools.getindices(kB, oindB)

            kABo = (kAo..., kBo...)

            kC = TupleTools.getindices(kABo, indCinoAB)

            C[kC...] += α * (CA == :C ? conj(vA) : vA) * (CB == :C ? conj(vB) : vB)
        end
    end
    C
end
