# Type-agnostic list of all active destructors
const type_specific_free_func_map::Dict{Ptr{Cvoid}, Ptr{Cvoid}} = Dict{Ptr{Cvoid}, Ptr{Cvoid}}()

const opaque_storage_lock = Threads.SpinLock()

# Used for testing purposes
Base.@ccallable function jlw_num_active_opaques()::UInt64 
    return length(type_specific_free_func_map) 
end

Base.@ccallable function jlw_free_opaque(ptr::Ptr{Cvoid})::Nothing
    ptr == C_NULL && return nothing
    lock(opaque_storage_lock) do
        ccall(type_specific_free_func_map[ptr], Cvoid, (Clonglong,), ptr)
        delete!(type_specific_free_func_map, ptr) # Must be called when destructors is already locked
        nothing
    end
    nothing
end

_pointable_type(T) = ismutabletype(T) ? T : Base.RefValue{T}
_maybe_ref(x) = ismutabletype(typeof(x)) ? x : Ref(x)
_maybe_deref(T, x) = ismutabletype(T) ? x : x[]

macro register_opaque_carrier(
    jltype::Union{Expr, Symbol, DataType}
)
    type_specific_free_func  = GlobalRef(__module__, gensym("destructor_$jltype"))
    type_specific_storage    = GlobalRef(__module__, gensym("gc_storage_$jltype"))

    return quote
        # Create a global type-specific storage
        const $type_specific_storage::Dict{Ptr{Cvoid}, _pointable_type($(esc(jltype)))} = Dict{Ptr{Cvoid}, _pointable_type($(esc(jltype)))}()
        
        # A function for removing an index at position ind
        # from the type-specific global storage
        function $type_specific_free_func(ptr::Ptr{Cvoid})
            delete!($type_specific_storage, ptr)
            nothing
        end

        $(GlobalRef(@__MODULE__, :carrier_type))(::Type{$(esc(jltype))}) = Ptr{Cvoid}
        
        function $(GlobalRef(@__MODULE__, :from_carrier))(::Type{$(esc(jltype))}, ptr::Ptr{Cvoid})
            lock(opaque_storage_lock) do
                stored = $type_specific_storage[ptr]::$(esc(jltype))
                _maybe_deref($(esc(jltype)), stored)
            end
        end

        function $(GlobalRef(@__MODULE__, :to_carrier))(obj::$(esc(jltype)))::Ptr{Cvoid}
            lock(opaque_storage_lock) do 
                obj_pointable = _maybe_ref(obj)
                ptr::Ptr{Cvoid} = pointer_from_objref(obj_pointable)
                
                $type_specific_storage[ptr] = obj_pointable
                type_specific_free_func_map[ptr] = @cfunction($type_specific_free_func, Cvoid, (Ptr{Cvoid},))
                return ptr
            end
        end
    end
end
