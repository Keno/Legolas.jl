#####
##### schema name/identifier parsing/validation
#####

const ALLOWED_SCHEMA_NAME_CHARACTERS = Char['-', '.', 'a':'z'..., '0':'9'...]

"""
    Legolas.is_valid_schema_name(x::AbstractString)

Return `true` if `x` is a valid schema name, return `false` otherwise.

Valid schema names are lowercase, alphanumeric, and may contain hyphens or periods.
"""
is_valid_schema_name(x::AbstractString) = all(i -> i in ALLOWED_SCHEMA_NAME_CHARACTERS, x)

#####
##### `SchemaVersion`
#####

"""
    Legolas.SchemaVersion{name,version}

A type representing a particular version of Legolas schema. The relevant `name` (a `Symbol`)
and `version` (an `Integer`) are surfaced as type parameters, allowing them to be utilized for
dispatch.

For more details and examples, please see `Legolas.jl/examples/tour.jl` and the
"Schema-Related Concepts/Conventions" section of the Legolas.jl documentation.

The constructor `SchemaVersion{name,version}()` will throw an `ArgumentError` if `version` is
negative.

See also: [`Legolas.@schema`](@ref)
"""
struct SchemaVersion{n,v}
    function SchemaVersion{n,v}() where {n,v}
        v isa Integer && v >= 0 || throw(ArgumentError("`version` in `SchemaVersion{_,version}` must be a non-negative integer, received: `($v)::$(typeof(v))`"))
        return new{n,v}()
    end
end

"""
    Legolas.SchemaVersion(name::AbstractString, version::Integer)

Return `Legolas.SchemaVersion{Symbol(name),version}()`.

Throws an `ArgumentError` if `name` is not a valid schema name.

Prefer using this constructor over `Legolas.SchemaVersion{Symbol(name),version}()` directly.
"""
function SchemaVersion(n::AbstractString, v::Integer)
    is_valid_schema_name(n) || throw(ArgumentError("argument is not a valid `Legolas.SchemaVersion` name: \"$n\""))
    return SchemaVersion{Symbol(n),v}()
end

SchemaVersion(sv::SchemaVersion) = sv

#####
##### `parse_identifier`
#####

"""
    Legolas.parse_identifier(id::AbstractString)

Given a valid schema version identifier `id` of the form:

    \$(names[1])@\$(versions[1]) > \$(names[2])@\$(versions[2]) > ... > \$(names[n])@\$(versions[n])

return an `n` element `Vector{SchemaVersion}` whose `i`th element is `SchemaVersion(names[i], versions[i])`.

Throws an `ArgumentError` if the provided string is not a valid schema version identifier.

For details regarding valid schema version identifiers and their structure, see the
"Schema-Related Concepts/Conventions" section of the Legolas.jl documentation.
"""
function parse_identifier(id::AbstractString)
    name_and_version_per_schema = [split(strip(x), '@') for x in split(id, '>')]
    results = SchemaVersion[]
    invalid = isempty(name_and_version_per_schema)
    if !invalid
        for nv in name_and_version_per_schema
            if length(nv) != 2
                invalid = true
                break
            end
            n, v = nv
            v = tryparse(Int, v)
            v isa Int && push!(results, SchemaVersion(n, v))
        end
    end
    (invalid || isempty(results)) && throw(ArgumentError("failed to parse seemingly invalid/malformed schema version identifier string: \"$id\""))
    return results
end

#####
##### `UnknownSchemaVersionError`
#####

struct UnknownSchemaVersionError <: Exception
    schema_version::SchemaVersion
    schema_provider_name::Union{Missing,Symbol}
    schema_provider_version::Union{Missing,VersionNumber}
end

UnknownSchemaVersionError(schema_version::SchemaVersion) = UnknownSchemaVersionError(schema_version, missing, missing)

function Base.showerror(io::IO, e::UnknownSchemaVersionError)
    print(io, """
              UnknownSchemaVersionError: encountered unknown Legolas schema version:

                name=\"$(name(e.schema_version))\"
                version=$(version(e.schema_version))

              This generally indicates that this schema has not been declared (i.e.
              the corresponding `@schema` and/or `@version` statements have not been
              executed) in the current Julia session.
              """)
    println(io)

    if !ismissing(e.schema_provider_name)
        provider_string = string(e.schema_provider_name)
        if !ismissing(e.schema_provider_version)
            provider_string *= string(" ", e.schema_provider_version)
        end
        print(io, """
                The table's metadata indicates that the table was created with a schema defined in:

                  $(provider_string)

                You likely need to load a compatible version of this package to populate your session with the schema definition.
                """)
    else
        print(io, """
                In practice, this can arise if you try to read a Legolas table with a
                prescribed schema, but haven't actually loaded the schema definition
                (or commonly, haven't loaded the dependency that contains the schema
                definition - check the versions of loaded packages/modules to confirm
                your environment is as expected).
                """)
    end
    println(io)

    print(io, """
              Note that if you're in this particular situation, you can still load the raw
              table as-is without Legolas (e.g. via `Arrow.Table(path_to_table)`).
              """)
    return nothing
end

#####
##### `SchemaVersion` accessors
#####

"""
    Legolas.name(::Legolas.SchemaVersion{n})

Return `n`.
"""
@inline name(::SchemaVersion{n}) where {n} = n

"""
    Legolas.version(::Legolas.SchemaVersion{n,v})

Return `v`.
"""
@inline version(::SchemaVersion{n,v}) where {n,v} = v

"""
    Legolas.parent(sv::Legolas.SchemaVersion)

Return the `Legolas.SchemaVersion` instance that corresponds to `sv`'s declared parent.
"""
@inline parent(::SchemaVersion) = nothing

"""
    Legolas.declared(sv::Legolas.SchemaVersion{name,version})

Return `true` if the schema version `name@version` has been declared via `@version` in the current Julia
session; return `false` otherwise.
"""
@inline declared(::SchemaVersion) = false

"""
    Legolas.identifier(::Legolas.SchemaVersion)

Return this `Legolas.SchemaVersion`'s fully qualified schema version identifier. This string is serialized
as the `\"$LEGOLAS_SCHEMA_QUALIFIED_METADATA_KEY\"` field value in table metadata for table
written via [`Legolas.write`](@ref).
"""
identifier(sv::SchemaVersion) = throw(UnknownSchemaVersionError(sv))

"""
    Legolas.schema_provider(::SchemaVersion)

Returns a NamedTuple with keys `name` and `version`. The name is a `Symbol` corresponding to the package which defines the schema version, if known; otherwise `nothing`. Likewise the `version` is a `VersionNumber` or `nothing`.
"""
schema_provider(::SchemaVersion) = (; name=nothing, version=nothing)
# shadow `pkgversion` so we don't fail on pre-1.9
pkgversion(m::Module) = isdefined(Base, :pkgversion) ? Base.pkgversion(m) : nothing

# Used in the implementation of `schema_provider`.
function defining_package_version(m::Module)
    rootmodule = Base.moduleroot(m)
    # Check if this module was defined in a package.
    path = pathof(rootmodule)
    path === nothing && return (; name=nothing, version=nothing)
    return (; name=Symbol(rootmodule), version=pkgversion(rootmodule))
end

"""
    Legolas.declared_fields(sv::Legolas.SchemaVersion)

Return a `NamedTuple{...,Tuple{Vararg{DataType}}` whose fields take the form:

    <name of field declared by `sv`> = <field's type>

If `sv` has a parent, the returned fields will include `declared_fields(parent(sv))`.
"""
declared_fields(sv::SchemaVersion) = throw(UnknownSchemaVersionError(sv))

@deprecate required_fields(sv) declared_fields(sv) false

"""
    Legolas.declaration(sv::Legolas.SchemaVersion)

Return a `Pair{String,Vector{NamedTuple}}` of the form

    schema_version_identifier::String => declared_field_infos::Vector{Legolas.DeclaredFieldInfo}

where `DeclaredFieldInfo` has the fields:

- `name::Symbol`: the declared field's name
- `type::Union{Symbol,Expr}`: the declared field's declared type constraint
- `parameterize::Bool`: whether or not the declared field is exposed as a parameter
- `statement::Expr`: the declared field's full assignment statement (as processed by `@version`, not necessarily as written)

Note that `declaration` is primarily intended to be used for interactive discovery purposes, and
does not include the contents of `declaration(parent(sv))`.
"""
declaration(sv::SchemaVersion) = throw(UnknownSchemaVersionError(sv))

"""
    Legolas.record_type(sv::Legolas.SchemaVersion)

Return the `Legolas.AbstractRecord` subtype associated with `sv`.

See also: [`Legolas.schema_version_from_record`](@ref)
"""
record_type(sv::SchemaVersion) = throw(UnknownSchemaVersionError(sv))

#####
##### `SchemaVersion` printing
#####

Base.show(io::IO, sv::SchemaVersion) = print(io, "SchemaVersion(\"$(name(sv))\", $(version(sv)))")

#####
##### `SchemaVersion` Arrow (de)serialization
#####

const LEGOLAS_SCHEMA_VERSION_ARROW_NAME = Symbol("JuliaLang.Legolas.SchemaVersion")
Arrow.ArrowTypes.arrowname(::Type{<:SchemaVersion}) = LEGOLAS_SCHEMA_VERSION_ARROW_NAME
Arrow.ArrowTypes.ArrowType(::Type{<:SchemaVersion}) = String
Arrow.ArrowTypes.toarrow(sv::SchemaVersion) = identifier(sv)
Arrow.ArrowTypes.JuliaType(::Val{LEGOLAS_SCHEMA_VERSION_ARROW_NAME}, ::Any) = SchemaVersion
Arrow.ArrowTypes.fromarrow(::Type{<:SchemaVersion}, id) = first(parse_identifier(id))

#####
##### `Tables.Schema` validation
#####

"""
    Legolas.accepted_field_type(sv::Legolas.SchemaVersion, T::Type)

Return the "maximal supertype" of `T` that is accepted by `sv` when evaluating a
field of type `>:T` for schematic compliance via [`Legolas.find_violation`](@ref);
see that function's docstring for an explanation of this function's use in context.

`SchemaVersion` authors may overload this function to broaden particular type
constraints that determine schematic compliance for their `SchemaVersion`, without
needing to broaden the type constraints employed by their `SchemaVersion`'s
record type.

Legolas itself defines the following default overloads:

    accepted_field_type(::SchemaVersion, T::Type) = T
    accepted_field_type(::SchemaVersion, ::Type{Any}) = Any
    accepted_field_type(::SchemaVersion, ::Type{UUID}) = Union{UUID,UInt128}
    accepted_field_type(::SchemaVersion, ::Type{Symbol}) = Union{Symbol,AbstractString}
    accepted_field_type(::SchemaVersion, ::Type{String}) = AbstractString
    accepted_field_type(sv::SchemaVersion, ::Type{<:Vector{T}}) where T = AbstractVector{<:(accepted_field_type(sv, T))}
    accepted_field_type(::SchemaVersion, ::Type{Vector}) = AbstractVector
    accepted_field_type(sv::SchemaVersion, ::Type{Union{T,Missing}}) where {T} = Union{accepted_field_type(sv, T),Missing}

Outside of these default overloads, this function should only be overloaded against specific
`SchemaVersion`s that are authored within the same module as the overload definition; to do
otherwise constitutes type piracy and should be avoided.
"""
@inline accepted_field_type(::SchemaVersion, T::Type) = T
accepted_field_type(::SchemaVersion, ::Type{Any}) = Any
accepted_field_type(::SchemaVersion, ::Type{UUID}) = Union{UUID,UInt128}
accepted_field_type(::SchemaVersion, ::Type{Symbol}) = Union{Symbol,AbstractString}
accepted_field_type(::SchemaVersion, ::Type{String}) = AbstractString
accepted_field_type(sv::SchemaVersion, ::Type{<:Vector{T}}) where T = AbstractVector{<:(accepted_field_type(sv, T))}
accepted_field_type(::SchemaVersion, ::Type{Vector}) = AbstractVector
accepted_field_type(sv::SchemaVersion, ::Type{Union{T,Missing}}) where {T} = Union{accepted_field_type(sv, T),Missing}
accepted_field_type(::SchemaVersion, ::Type{Missing}) = Missing

"""
    Legolas.find_violation(ts::Tables.Schema, sv::Legolas.SchemaVersion)

For each field `f::F` declared by `sv`:

- Define `A = Legolas.accepted_field_type(sv, F)`
- If `f::T` is present in `ts`, ensure that `T <: A` or else immediately return `f::Symbol => T::DataType`.
- If `f` isn't present in `ts`, ensure that `Missing <: A` or else immediately return `f::Symbol => missing::Missing`.

Otherwise, return `nothing`.

To return all violations instead of just the first, use [`Legolas.find_violations`](@ref).

See also: [`Legolas.validate`](@ref), [`Legolas.complies_with`](@ref), [`Legolas.find_violations`](@ref).
"""
find_violation(::Tables.Schema, sv::SchemaVersion) = throw(UnknownSchemaVersionError(sv))

"""
    Legolas.find_violations(ts::Tables.Schema, sv::Legolas.SchemaVersion)

Return a `Vector{Pair{Symbol,Union{Type,Missing}}}` of all of `ts`'s violations with respect to `sv`.

This function's notion of "violation" is defined by [`Legolas.find_violation`](@ref), which immediately returns the first violation found; prefer to use that function instead of `find_violations` in situations where you only need to detect *any* violation instead of *all* violations.

See also: [`Legolas.validate`](@ref), [`Legolas.complies_with`](@ref), [`Legolas.find_violation`](@ref).
"""
find_violations(::Tables.Schema, sv::SchemaVersion) = throw(UnknownSchemaVersionError(sv))

"""
    Legolas.validate(ts::Tables.Schema, sv::Legolas.SchemaVersion)

Throws a descriptive `ArgumentError` if any violations are found, else return `nothing`.

See also: [`Legolas.find_violation`](@ref), [`Legolas.find_violations`](@ref), [`Legolas.find_violation`](@ref), [`Legolas.complies_with`](@ref)
"""
function validate(ts::Tables.Schema, sv::SchemaVersion)
    results = find_violations(ts, sv)
    isempty(results) && return nothing

    field_err = Symbol[]
    type_err = Tuple{Symbol,Type,Type}[]
    for result in results
        field, violation = result
        if ismissing(violation)
            push!(field_err, field)
        else
            expected = getfield(declared_fields(sv), field)
            push!(type_err, (field, expected, violation))
        end
    end
    err_msg = "Tables.Schema violates Legolas schema `$(string(name(sv), "@", version(sv)))`:\n"
    for err in field_err
        err_msg *= " - Could not find declared field: `$err`\n"
    end
    for (field, expected, violation) in type_err
        err_msg *= " - Incorrect type: `$field` expected `<:$expected`, found `$violation`\n"
    end
    err_msg *= "Provided $ts"
    throw(ArgumentError(err_msg))
end

"""
    Legolas.complies_with(ts::Tables.Schema, sv::Legolas.SchemaVersion)

Return `isnothing(find_violation(ts, sv))`.

See also: [`Legolas.find_violation`](@ref), [`Legolas.find_violations`](@ref), [`Legolas.validate`](@ref)
"""
complies_with(ts::Tables.Schema, sv::SchemaVersion) = isnothing(find_violation(ts, sv))

#####
##### `AbstractRecord`
#####

abstract type AbstractRecord <: Tables.AbstractRow end

@inline Tables.getcolumn(r::AbstractRecord, i::Int) = getfield(r, i)
@inline Tables.getcolumn(r::AbstractRecord, nm::Symbol) = getfield(r, nm)
@inline Tables.columnnames(r::AbstractRecord) = fieldnames(typeof(r))
@inline Tables.schema(::AbstractVector{R}) where {R<:AbstractRecord} = Tables.Schema(fieldnames(R), fieldtypes(R))

"""
    Legolas.schema_version_from_record(record::Legolas.AbstractRecord)

Return the `Legolas.SchemaVersion` instance associated with `record`.

See also: [`Legolas.record_type`](@ref)
"""
function schema_version_from_record end

#####
##### `@schema`
#####

_schema_declared_in_module(::Val) = nothing

"""
    @schema "name" Prefix

Declare a Legolas schema with the given `name`. Types generated by subsequent
[`@version`](@ref) declarations for this schema will be prefixed with `Prefix`.

For more details and examples, please see `Legolas.jl/examples/tour.jl`.
"""
macro schema(schema_name, schema_prefix)
    schema_name isa String || return :(throw(ArgumentError("`name` provided to `@schema` must be a string literal")))
    occursin('@', schema_name) && return :(throw(ArgumentError("`name` provided to `@schema` should not include an `@` version clause")))
    is_valid_schema_name(schema_name) || return :(throw(ArgumentError("`name` provided to `@schema` is not a valid `Legolas.SchemaVersion` name: \"" * $schema_name * "\"")))
    schema_prefix isa Symbol || return :(throw(ArgumentError(string("`Prefix` provided to `@schema` is not a valid type name: ", $(Base.Meta.quot(schema_prefix))))))
    return quote
        # This approach provides some safety against accidentally replacing another module's schema's name,
        # without making it annoying to reload code/modules in an interactive development context.
        m = $Legolas._schema_declared_in_module(Val(Symbol($schema_name)))
        if m isa Module && string(m) != string(@__MODULE__)
            throw(ArgumentError(string("A schema with this name was already declared by a different module: ", m)))
        else
            $Legolas._schema_declared_in_module(::Val{Symbol($schema_name)}) = @__MODULE__
            if !isdefined(@__MODULE__, :__legolas_schema_name_from_prefix__)
                $(esc(:__legolas_schema_name_from_prefix__))(::Val) = nothing
            end
            $(esc(:__legolas_schema_name_from_prefix__))(::Val{$(Base.Meta.quot(schema_prefix))}) = $(Base.Meta.quot(Symbol(schema_name)))
        end
        nothing
    end
end

#####
##### `@version`
#####

struct SchemaVersionDeclarationError <: Exception
    message::String
end

SchemaVersionDeclarationError(x, y, args...) = SchemaVersionDeclarationError(string(x, y, args...))

function Base.showerror(io::IO, e::SchemaVersionDeclarationError)
    print(io, """
              SchemaVersionDeclarationError: $(e.message)

              Note that valid `@version` declarations meet these expectations:

              - `@version`'s first argument must be of the form `RecordType` or
              `RecordType > ParentRecordType`, where a valid record type name
              takes the form \$(Prefix)V\$(n)` where `Prefix` is a symbol registered
              for a particular schema via a prior `@schema` declaration and `n`
              is a non-negative integer literal.

              - `@version` declarations must declare at least one field, and must not
              declare duplicate fields within the same declaration.

              - New versions of a given schema may only be declared within the same
              module that declared the schema.
              """)
end

struct DeclaredFieldInfo
    name::Symbol
    type::Union{Symbol,Expr}
    parameterize::Bool
    statement::Expr
end

# We maintain an alias to the deprecated name for this type, xref https://github.com/beacon-biosignals/Legolas.jl/pull/100
Base.@deprecate_binding RequiredFieldInfo DeclaredFieldInfo

Base.:(==)(a::DeclaredFieldInfo, b::DeclaredFieldInfo) = _compare_fields(==, a, b)

function _parse_declared_field_info!(f)
    f isa Symbol && (f = Expr(:(::), f, :Any))
    f.head == :(::) && (f = Expr(:(=), f, f.args[1]))
    f.head == :(=) && f.args[1] isa Symbol && (f.args[1] = Expr(:(::), f.args[1], :Any))
    f.head == :(=) && f.args[1].head == :(::) || error("couldn't normalize field expression: $f")
    type = f.args[1].args[2]
    parameterize = false
    if type isa Expr && type.head == :(<:)
        type = type.args[1]
        parameterize = true
    end
    return DeclaredFieldInfo(f.args[1].args[1], type, parameterize, f)
end

function _has_valid_child_field_types(child_fields::NamedTuple, parent_fields::NamedTuple)
    for (name, child_type) in pairs(child_fields)
        if haskey(parent_fields, name)
            child_type <: parent_fields[name] || return false
        end
    end
    return true
end

function _check_for_expected_field(schema::Tables.Schema, name::Symbol, ::Type{T}) where {T}
    i = findfirst(==(name), schema.names)
    if isnothing(i)
        Missing <: T || return missing
    else
        schema.types[i] <: T || return schema.types[i]
    end
    return nothing
end

function _generate_schema_version_definitions(schema_version::SchemaVersion, parent, declared_field_names_types, schema_version_declaration)
    identifier_string = string(name(schema_version), '@', version(schema_version))
    declared_field_names_types = declared_field_names_types
    if !isnothing(parent)
        identifier_string = string(identifier_string, '>',  Legolas.identifier(parent))
        declared_field_names_types = merge(Legolas.declared_fields(parent), declared_field_names_types)
    end
    quoted_schema_version_type = Base.Meta.quot(typeof(schema_version))
    return quote
        @inline $Legolas.declared(::$quoted_schema_version_type) = true
        @inline $Legolas.identifier(::$quoted_schema_version_type) = $identifier_string
        $Legolas.schema_provider(::$quoted_schema_version_type) = $Legolas.defining_package_version(@__MODULE__)
        @inline $Legolas.parent(::$quoted_schema_version_type) = $(Base.Meta.quot(parent))
        $Legolas.declared_fields(::$quoted_schema_version_type) = $declared_field_names_types
        $Legolas.declaration(::$quoted_schema_version_type) = $(Base.Meta.quot(schema_version_declaration))
    end
end

function _generate_validation_definitions(schema_version::SchemaVersion)
    # When `fail_fast == true`, return first violation found rather than all violations
    _violation_check = (; fail_fast::Bool) -> begin
        statements = Expr[]
        violations = gensym()
        fail_fast || push!(statements, :($violations = Pair{Symbol,Union{Type,Missing}}[]))
        for (fname, ftype) in pairs(declared_fields(schema_version))
            fname = Base.Meta.quot(fname)
            found = :($fname => result)
            handle_found = fail_fast ? :(return $found) : :(push!($violations, $found))
            push!(statements, quote
                S = $Legolas.accepted_field_type(sv, $ftype)
                result = $Legolas._check_for_expected_field(ts, $fname, S)
                isnothing(result) || $handle_found
            end)
        end
        push!(statements, :(return $(fail_fast ? :nothing : violations)))
        return statements
    end
    return quote
        function $(Legolas).find_violation(ts::$(Tables).Schema, sv::$(Base.Meta.quot(typeof(schema_version))))
            $(_violation_check(; fail_fast=true)...)
        end

        # Multiple violation reporting
        function $(Legolas).find_violations(ts::$(Tables).Schema, sv::$(Base.Meta.quot(typeof(schema_version))))
            $(_violation_check(; fail_fast=false)...)
        end
    end
end

_schema_version_from_record_type(::Nothing) = nothing

# Note also that this function's implementation is allowed to "observe" `Legolas.declared_fields(parent)`
# (if a parent exists), but is NOT allowed to "observe" `Legolas.declaration(parent)`, since the latter
# includes the parent's declared field RHS statements. We cannot interpolate/incorporate these statements
# in the child's record type definition because they may reference bindings from the parent's `@version`
# callsite that are not available/valid at the child's `@version` callsite.
function _generate_record_type_definitions(schema_version::SchemaVersion, record_type_symbol::Symbol, constraints::AbstractVector)
    # generate `schema_version_type_alias_definition`
    T = Symbol(string(record_type_symbol, "SchemaVersion"))
    schema_version_type_alias_definition = :(const $T = $(Base.Meta.quot(typeof(schema_version))))

    # generate building blocks for record type definitions
    record_fields = declared_fields(schema_version)
    _, declared_field_infos = declaration(schema_version)
    declared_field_infos = Dict(f.name => f for f in declared_field_infos)
    type_param_defs = Expr[]
    names_of_parameterized_fields = Symbol[]
    field_definitions = Expr[]
    field_assignments = Expr[]
    parametric_field_assignments = Expr[]
    for (fname, ftype) in pairs(record_fields)
        fsym = Base.Meta.quot(fname)
        T = Base.Meta.quot(ftype)
        fdef = :($fname::$T)
        info = get(declared_field_infos, fname, nothing)
        if !isnothing(info)
            fcatch = quote
                if $fname isa $(info.type)
                    throw(ArgumentError("Invalid value set for field `$($fsym)` ($(repr($(fname))))"))
                else
                    throw(ArgumentError("Invalid value set for field `$($fsym)`, expected $($(info.type)), got a value of type $(typeof($fname)) ($(repr($(fname))))"))
                end
            end
            if info.parameterize
                # As we disallow the use of fields which start with an underscore then the
                # following parameter should not conflict with any user defined fields.
                # Additionally, as these are static parameters users will not be able to
                # overwrite them in custom field assignments.
                T = Symbol('_', join(titlecase.(split(string(fname), '_'))))
                push!(type_param_defs, :($T <: $(info.type)))
                push!(names_of_parameterized_fields, fname)
                fdef = :($fname::$T)
                fstmt = quote
                    try
                        $fname = $(info.statement.args[2])
                    catch
                        $fcatch
                    end
                    if !($fname isa $(info.type))
                        throw(TypeError($(Base.Meta.quot(record_type_symbol)), "field `$($fsym)`", $(info.type), $fname))
                    end
                end
                fstmt_par = quote
                    try
                        $fname = $(info.statement.args[2])
                        $fname = convert($T, $fname)::$T
                    catch
                        $fcatch
                    end
                end
            else
                fstmt = quote
                    try
                        $fname = $(info.statement.args[2])
                        $fname = convert($T, $fname)::$T
                    catch
                        $fcatch
                    end
                end
                fstmt_par = fstmt
            end
            push!(field_assignments, fstmt)
            push!(parametric_field_assignments, fstmt_par)
        end
        push!(field_definitions, fdef)
    end

    # generate `parent_record_application`
    field_kwargs = [Expr(:kw, n, :missing) for n in keys(record_fields)]
    parent_record_application = nothing
    parent = Legolas.parent(schema_version)
    if !isnothing(parent)
        p = gensym()
        P = Base.Meta.quot(record_type(parent))
        parent_record_field_names = keys(declared_fields(parent))
        parent_record_application = quote
            $p = $P(; $(parent_record_field_names...))
            $((:($n = $p.$n) for n in parent_record_field_names)...)
        end
    end

    # generate `inner_constructor_definitions` and `outer_constructor_definitions`
    R = record_type_symbol
    kwargs_from_row = [Expr(:kw, n, :(get(row, $(Base.Meta.quot(n)), missing))) for n in keys(record_fields)]
    outer_constructor_definitions = quote
        $R(row) = $R(; $(kwargs_from_row...))
    end
    if isempty(type_param_defs)
        inner_constructor_definitions = quote
            function $R(; $(field_kwargs...))
                $parent_record_application
                $(field_assignments...)
                $(constraints...)
                return new($(keys(record_fields)...))
            end
        end
    else
        type_param_names = [p.args[1] for p in type_param_defs]
        inner_constructor_definitions = quote
            function $R{$(type_param_names...)}(; $(field_kwargs...)) where {$(type_param_names...)}
                $parent_record_application
                $(parametric_field_assignments...)
                $(constraints...)
                return new{$(type_param_names...)}($(keys(record_fields)...))
            end
            function $R(; $(field_kwargs...))
                $parent_record_application
                $(field_assignments...)
                $(constraints...)
                return new{$((:(typeof($n)) for n in names_of_parameterized_fields)...)}($(keys(record_fields)...))
            end
        end
        outer_constructor_definitions = quote
            $outer_constructor_definitions
            $R{$(type_param_names...)}(row) where {$(type_param_names...)} = $R{$(type_param_names...)}(; $(kwargs_from_row...))
        end
    end

    # generate `arrow_overload_definitions`
    record_type_arrow_name = string("JuliaLang.Legolas.Generated.", Legolas.name(schema_version), '.', Legolas.version(schema_version))
    record_type_arrow_name = Base.Meta.quot(Symbol(record_type_arrow_name))
    arrow_overload_definitions = quote
        $Arrow.ArrowTypes.arrowname(::Type{<:$R}) = $record_type_arrow_name
        $Arrow.ArrowTypes.ArrowType(::Type{R}) where {R<:$R} = NamedTuple{fieldnames(R),Tuple{fieldtypes(R)...}}
        $Arrow.ArrowTypes.toarrow(r::$R) = NamedTuple(r)
        $Arrow.ArrowTypes.JuliaType(::Val{$record_type_arrow_name}, ::Any) = $R
        function $Arrow.ArrowTypes.fromarrowstruct(::Type{<:$R}, ::Val{fnames},
                                                   $(keys(record_fields)...)) where {fnames}
            nt = NamedTuple{fnames}(($(keys(record_fields)...),))
            return $R(; nt...)
        end
    end

    return quote
        $schema_version_type_alias_definition
        struct $R{$(type_param_defs...)} <: $Legolas.AbstractRecord
            $(field_definitions...)
            $inner_constructor_definitions
        end
        $outer_constructor_definitions
        $arrow_overload_definitions
        $Legolas.record_type(::$(Base.Meta.quot(typeof(schema_version)))) = $R
        $Legolas.schema_version_from_record(::$R) = $schema_version
        $Legolas._schema_version_from_record_type(::Type{<:$R}) = $schema_version
    end
end

function _parse_record_type_symbol(t::Symbol)
    pv = rsplit(string(t), 'V'; limit=2)
    if length(pv) == 2
        p, v = pv
        p = Symbol(p)
        v = tryparse(Int, v)
        v isa Int && return (p, v)
    end
    return SchemaVersionDeclarationError("provided record type symbol is malformed: ", t)
end

"""
    @version RecordType begin
        declared_field_expression_1
        declared_field_expression_2
        ⋮
    end

    @version RecordType > ParentRecordType begin
        declared_field_expression_1
        declared_field_expression_2
        ⋮
    end

Given a prior `@schema` declaration of the form:

    @schema "example.name" Name

...the `n`th version of `example.name` can be declared in the same module via a `@version` declaration of the form:

    @version NameV\$(n) begin
        declared_field_expression_1
        declared_field_expression_2
        ⋮
    end

...which generates types definitions for the `NameV\$(n)` type (a `Legolas.AbstractRecord` subtype) and
`NameV\$(n)SchemaVersion` type (an alias of `typeof(SchemaVersion("example.name", n))`), as well as the
necessary definitions to overload relevant Legolas methods with specialized behaviors in accordance with
the declared fields.

If the declared schema version has a parent, it should be specified via the optional `> ParentRecordType`
clause. `ParentRecordType` should refer directly to an existing Legolas-generated record type.

Each `declared_field_expression` declares a field of the schema version, and is an expression of the form
`field::F = rhs` where:

- `field` is the corresponding field's name
- `::F` denotes the field's type constraint (if elided, defaults to `::Any`).
- `rhs` is the expression which produces `field::F` (if elided, defaults to `field`).

Accounting for all of the aforementioned allowed elisions, valid `declared_field_expression`s include:

- `field::F = rhs`
- `field::F` (interpreted as `field::F = field`)
- `field = rhs` (interpreted as `field::Any = rhs`)
- `field` (interpreted as `field::Any = field`)

`F` is generally a type literal, but may also be an expression of the form `(<:T)`, in which case
the declared schema version's generated record type will expose a type parameter (constrained to be
a subtype of `T`) for the given field. For example:

    julia> @schema "example.foo" Foo

    julia> @version FooV1 begin
               x::Int
               y::(<:Real)
           end

    julia> FooV1(x=1, y=2.0)
    FooV1{Float64}: (x = 1, y = 2.0)

    julia> FooV1{Float32}(x=1, y=2)
    FooV1{Float32}: (x = 1, y = 2.0f0)

    julia> FooV1(x=1, y="bad")
    ERROR: TypeError: in FooV1, in _y_T, expected _y_T<:Real, got Type{String}

This macro will throw a `Legolas.SchemaVersionDeclarationError` if:

- The provided `RecordType` does not follow the `\$(Prefix)V\$(n)` format, where `Prefix` was
  previously associated with a given schema by a prior `@schema` declaration.
- There are no declared field expressions, duplicate fields are declared, or a given declared
  field expression is invalid.
- (if a parent is specified) The `@version` declaration does not comply with its parent's
  `@version` declaration, or the parent hasn't yet been declared at all.

Note that this macro expects to be evaluated within top-level scope.

For more details and examples, please see `Legolas.jl/examples/tour.jl` and the
"Schema-Related Concepts/Conventions" section of the Legolas.jl documentation.
"""
macro version(record_type, declared_fields_block=nothing)
    # parse `record_type`
    if record_type isa Symbol
        parent_record_type = nothing
    elseif record_type isa Expr && record_type.head == :call && length(record_type.args) == 3 &&
           record_type.args[1] == :> && record_type.args[2] isa Symbol
        parent_record_type = record_type.args[3]
        record_type = record_type.args[2]
    else
        return :(throw(SchemaVersionDeclarationError("provided record type expression is malformed: ", $(Base.Meta.quot(record_type)))))
    end
    x = _parse_record_type_symbol(record_type)
    x isa SchemaVersionDeclarationError && return :(throw($x))
    schema_prefix, schema_version_integer = x
    quoted_schema_prefix = Base.Meta.quot(schema_prefix)

    # parse `declared_fields_block`
    declared_field_statements = Any[]
    declared_constraint_statements = Any[]
    if declared_fields_block isa Expr && declared_fields_block.head == :block && !isempty(declared_fields_block.args)
        for f in declared_fields_block.args
            if f isa LineNumberNode
                continue
            elseif f isa Expr && f.head === :macrocall && f.args[1] === Symbol("@check")
                constraint_expr = Base.macroexpand(Legolas, f)
                # Update the expression such that a failure shows the location of the user
                # defined `@check` call. Ideally `Meta.replace_sourceloc!` would do this.
                if f.args[2] isa LineNumberNode
                    constraint_expr = Expr(:block, f.args[2], constraint_expr)
                end
                push!(declared_constraint_statements, constraint_expr)
            elseif isempty(declared_constraint_statements)
                push!(declared_field_statements, f)
            else
                return :(throw(SchemaVersionDeclarationError("all `@version` field expressions must be defined before constraints:\n", $(Base.Meta.quot(declared_fields_block)))))
            end
        end
    end
    declared_field_infos = DeclaredFieldInfo[]
    for stmt in declared_field_statements
        original_stmt = Base.Meta.quot(deepcopy(stmt))
        try
            push!(declared_field_infos, _parse_declared_field_info!(stmt))
        catch
            return :(throw(SchemaVersionDeclarationError("malformed `@version` field expression: ", $original_stmt)))
        end
    end
    if !allunique(f.name for f in declared_field_infos)
        msg = string("cannot have duplicate field names in `@version` declaration; received: ", [f.name for f in declared_field_infos])
        return :(throw(SchemaVersionDeclarationError($msg)))
    end
    invalid_field_names = filter!(fname -> startswith(string(fname), '_'), [f.name for f in declared_field_infos])
    if !isempty(invalid_field_names)
        msg = string("cannot have field name which start with an underscore in `@version` declaration: ", invalid_field_names)
        return :(throw(SchemaVersionDeclarationError($msg)))
    end
    declared_field_names_types = Expr(:tuple, Expr(:parameters, (Expr(:kw, f.name, esc(f.type)) for f in declared_field_infos)...))
    constraints = [Base.Meta.quot(ex) for ex in declared_constraint_statements]

    return quote
        if !isdefined((@__MODULE__), :__legolas_schema_name_from_prefix__)
            throw(SchemaVersionDeclarationError("no prior `@schema` declaration found in current module"))
        elseif isnothing((@__MODULE__).__legolas_schema_name_from_prefix__(Val($quoted_schema_prefix)))
            throw(SchemaVersionDeclarationError(string("missing prior `@schema` declaration for `", $quoted_schema_prefix, "` in current module")))
        else
            schema_name = (@__MODULE__).__legolas_schema_name_from_prefix__(Val($quoted_schema_prefix))
            schema_version = $Legolas.SchemaVersion{schema_name,$schema_version_integer}()
            parent = $Legolas._schema_version_from_record_type($(esc(parent_record_type)))

            declared_identifier = string(schema_name, '@', $schema_version_integer)
            if !isnothing(parent)
                declared_identifier = string(declared_identifier, '>', $Legolas.name(parent), '@', $Legolas.version(parent))
            end
            schema_version_declaration = declared_identifier => $(Base.Meta.quot(declared_field_infos))

            if $Legolas.declared(schema_version) && $Legolas.declaration(schema_version) != schema_version_declaration
                throw(SchemaVersionDeclarationError("invalid redeclaration of existing schema version; all `@version` redeclarations must exactly match previous declarations"))
            elseif parent isa $Legolas.SchemaVersion && $Legolas.name(parent) == schema_name
                throw(SchemaVersionDeclarationError("cannot extend from another version of the same schema"))
            elseif parent isa $Legolas.SchemaVersion && !($Legolas._has_valid_child_field_types($declared_field_names_types, $Legolas.declared_fields(parent)))
                throw(SchemaVersionDeclarationError("declared field types violate parent's field types"))
            else
                Base.@__doc__($(Base.Meta.quot(record_type)))
                $(esc(:eval))($Legolas._generate_schema_version_definitions(schema_version, parent, $declared_field_names_types, schema_version_declaration))
                $(esc(:eval))($Legolas._generate_validation_definitions(schema_version))
                $(esc(:eval))($Legolas._generate_record_type_definitions(schema_version, $(Base.Meta.quot(record_type)), [$(constraints...)]))
            end
        end
        nothing
    end
end

#####
##### Base overload definitions
#####

# Field-wise comparison for any two objects with exactly the same type. Most record
# comparisons will hit this method.
function _compare_fields(eq, x::T, y::T) where {T}
    return all(i -> eq(getfield(x, i), getfield(y, i)), 1:fieldcount(T))
end

# Field-wise comparison of two arbitrary records, with equality contingent on matching
# schemas. Record comparisons for parametric record types with mismatched type parameters
# will hit this method, as well as mismatched record types (which will not compare equal).
function _compare_fields(eq, x::AbstractRecord, y::AbstractRecord)
    svx = schema_version_from_record(x)
    svy = schema_version_from_record(y)
    return svx === svy && all(i -> eq(getfield(x, i), getfield(y, i)), 1:nfields(x))
end

Base.:(==)(x::AbstractRecord, y::AbstractRecord) = _compare_fields(==, x, y)

Base.isequal(x::AbstractRecord, y::AbstractRecord) = _compare_fields(isequal, x, y)

function Base.hash(r::AbstractRecord, h::UInt)
    for i in nfields(r):-1:1
        h = hash(getfield(r, i), h)
    end
    return hash(typeof(r), h)
end

function Base.NamedTuple(r::AbstractRecord)
    names = fieldnames(typeof(r))
    return NamedTuple{names}(map(x -> getfield(r, x), names))
end
