    module ELF
    include("constants.jl")
    using StrPack
    using DWARF
    using ObjFileBase
    import Base: start, next, done, endof, length, getindex
    import Base: read, readuntil, write, readbytes, seek, seekstart, position
    import Base: show, showcompact
    import Base: sizeof
    import ObjFileBase: readmeta, debugsections, deref, sectionoffset, sectionaddress,
        sectionsize, Section, endianness, replace_sections_from_memory, strtab_lookup,
        getSectionLoadAddress, sectionname, load_strtab, handle
    import StrPack: unpack

    abstract ELFFile

    #
    # Represents the actual ELF file
    #
    immutable ELFHandle{T<:IO} <: ObjectHandle
        io::T
        start::Int
        file::ELFFile
    end

    abstract ELFHeader
    abstract ELFSectionHeader <: Section{ELFHandle}
    abstract ELFSymtabEntry
    abstract ELFRel
    abstract ELFRela
    abstract ELFProgramHeader

    sheader(::Type{ELFHeader}) = ELFSectionHeader
    pheader(::Type{ELFHeader}) = ELFProgramHeader
    symtype(::Type{ELFSectionHeader}) = ELFSymtabEntry

    module ELF32
        import ELF
        using StrPack
        @struct immutable Header <: ELF.ELFHeader
            e_type::Uint16
            e_machine::Uint16
            e_version::Uint32
            e_entry::Uint32
            e_phoff::Uint32
            e_shoff::Uint32
            e_flags::Uint32
            e_ehsize::Uint16
            e_phentsize::Uint16
            e_phnum::Uint16
            e_shentsize::Uint16
            e_shnum::Uint16
            e_shstrndx::Uint16
        end

        @struct immutable SectionHeader <: ELF.ELFSectionHeader
            sh_name::Uint32
            sh_type::Uint32
            sh_flags::Uint32
            sh_addr::Uint32
            sh_offset::Uint32
            sh_size::Uint32
            sh_link::Uint32
            sh_info::Uint32
            sh_addralign::Uint32
            sh_entsize::Uint32
        end

        @struct immutable SymtabEntry <: ELF.ELFSymtabEntry
            st_name::Uint32
            st_value::Uint32
            st_size::Uint32
            st_info::Uint8
            st_other::Uint8
            st_shndx::Uint16
        end

        @struct immutable Rel <: ELF.ELFRel
            r_offset::Uint32
            r_info::Uint32
        end

        @struct immutable Rela <: ELF.ELFRel
            r_offset::Uint32
            r_info::Uint32
            r_addend::Int32
        end

        @struct immutable ProgramHeader <: ELF.ELFProgramHeader
            p_type::Uint32
            p_offset::Uint32
            p_vaddr::Uint32
            p_paddr::Uint32
            p_filesz::Uint32
            p_memsz::Uint32
            p_flags::Uint32
            p_align::Uint32
        end

        type File <: ELF.ELFFile
            endianness::Symbol
            ei_version::Uint8
            ei_osabi::Uint8
            header::Header
        end
        ELF.sheader(::Type{File}) = SectionHeader
        ELF.pheader(::Type{File}) = ProgamHeader
        ELF.symtype(::Type{SectionHeader}) = SymtabEntry
    end

    module ELF64
        import ELF
        using StrPack
        @struct immutable Header <: ELF.ELFHeader
            e_type::Uint16
            e_machine::Uint16
            e_version::Uint32
            e_entry::Uint64
            e_phoff::Uint64
            e_shoff::Uint64
            e_flags::Uint32
            e_ehsize::Uint16
            e_phentsize::Uint16
            e_phnum::Uint16
            e_shentsize::Uint16
            e_shnum::Uint16
            e_shstrndx::Uint16
        end

        @struct immutable SectionHeader <: ELF.ELFSectionHeader
            sh_name::Uint32
            sh_type::Uint32
            sh_flags::Uint64
            sh_addr::Uint64
            sh_offset::Uint64
            sh_size::Uint64
            sh_link::Uint32
            sh_info::Uint32
            sh_addralign::Uint64
            sh_entsize::Uint64
        end

        @struct immutable SymtabEntry <: ELF.ELFSymtabEntry
            st_name::Uint32
            st_info::Uint8
            st_other::Uint8
            st_shndx::Uint16
            st_value::Uint32
            st_size::Uint64
        end

        @struct immutable Rel <: ELF.ELFRel
            r_offset::Uint64
            r_info::Uint64
        end

        @struct immutable Rela <: ELF.ELFRel
            r_offset::Uint64
            r_info::Uint64
            r_addend::Int64
        end

        @struct immutable ProgramHeader <: ELF.ELFProgramHeader
            p_type::Uint32
            p_flags::Uint32
            p_offset::Uint64
            p_vaddr::Uint64
            p_paddr::Uint64
            p_filesz::Uint64
            p_memsz::Uint64
            p_align::Uint64
        end

        type File <: ELF.ELFFile
            endianness::Symbol
            ei_version::Uint8
            ei_osabi::Uint8
            header::Header
        end
        ELF.sheader(::Type{File}) = SectionHeader
        ELF.pheader(::Type{File}) = ProgamHeader
        ELF.symtype(::Type{SectionHeader}) = SymtabEntry
    end

    sectionsize(sh::ELFSectionHeader) = sh.sh_size
    sectionoffset(sh::ELFSectionHeader) = sh.sh_offset
    sectionaddress(sh::ELFSectionHeader) = sh.sh_addr

    # Definitions for ELF Handle
    ELFHandle{T<:IO}(io::T, file::ELFFile) = ELFHandle{T}(io,position(io),file)
    function show(io::IO,h::ELFHandle)
        print(io,"ELF Handle (")
        if typeof(h.file) == ELF32.File
            print(io,"32-bit")
        elseif typeof(h.file) == ELF64.File
            print(io,"64-bit")
        else
            error("Unrecognized ELF type")
        end
        print(io,")")
    end

    for f in (:read,:readuntil,:write)
        @eval $(f){T<:IO}(io::ELFHandle{T},args...) = $(f)(io.io,args...)
    end
    readbytes{T<:IO}(io::ELFHandle{T},num::Integer) = readbytes(io.io,num)
    seek{T<:IO}(io::ELFHandle{T},pos::Integer) = seek(io.io,io.start+pos)
    seekstart(io::ELFHandle) = seek(io.io,io.start)
    position{T<:IO}(io::ELFHandle{T}) = position(io.io)-io.start
    unpack{T,ioT<:IO}(h::ELFHandle{ioT},::Type{T}) = unpack(h.io,T)
    endianness(h::ELFHandle) = h.file.endianness


    function endianness(ei_data::Uint8)
        if ei_data == ELFDATA2MSB
            :BigEndian
        elseif ei_data == ELFDATA2LSB
            :LittleEndian
        else
            error("Invalid Data Specification")
        end
    end

    function readmeta(io::IO,::Type{ELFHandle})
        start = position(io)
        mag0 = read(io,Uint8)
        mag1 = read(io,Uint8)
        mag2 = read(io,Uint8)
        mag3 = read(io,Uint8)
        if((mag0 != '\177') || (mag1 != 'E') || (mag2 != 'L') || (mag3 != 'F'))
            throw(ObjFileBase.MagicMismatch("Magic Number does not match"))
        end
        class = read(io,Uint8)
        data = read(io,Uint8)
        version = read(io,Uint8)
        osabi = read(io,Uint8)
        abiversion = read(io,Uint8)
        skip(io,7)
        if class == ELFCLASS32
            header = unpack(io,ELF32.Header,endianness(data))
            file = ELF32.File(endianness(data),version,osabi,header)
        elseif class == ELFCLASS64
            header = unpack(io,ELF64.Header,endianness(data))
            file = ELF64.File(endianness(data),version,osabi,header)
        else
            error("Invalid File Class")
        end
        seek(io,start)
        ELFHandle(io,file)
    end

    function read(io::IO,::Type{ELFProgramHeader},f::ELFFile)
        s = StrPack.calcsize(pheader(typeof(f)))
        if s > f.header.e_phentsize
            error("Missing data for program header")
        end
        ret = unpack(io,sheader(typeof(f)),f.endianness)
        skip(io,f.header.e_phentsize-s)
        ret
    end

    function read(io::IO,::Type{ELFSectionHeader},f::ELFFile)
        s = StrPack.calcsize(sheader(typeof(f)))
        if s > f.header.e_shentsize
            error("Missing data for section header")
        end
        ret = unpack(io,sheader(typeof(f)),f.endianness)
        skip(io,f.header.e_shentsize-s)
        ret
    end

    function strtab_lookup(io,strtable::ELFSectionHeader,index)
        seek(io,strtable.sh_offset+index)
        strip(readuntil(io,'\0'),'\0')
    end

    function read(io::IO,x::Array{Uint8,1},file::ELFFile,header::ELFProgramHeader)
        seek(io,header.p_offset)
        read(io,x)
    end

    function read(io::IO,x::Array{Uint8,1},file::ELFFile,header::ELFSectionHeader)
        seek(io,header.sh_offset)
        read(io,x)
    end

    function read(io::IO,file::ELFFile,header::ELFSectionHeader)
        x = Array(Uint8,header.sh_size)
        read(io,x,file,header)
        x
    end

    function read(io::IO,file::ELFFile,header::ELFProgramHeader)
        x = Array(Uint8,header.p_filesz)
        read(io,x,file,header)
        x
    end

    # Access to sections
    function sectionname(header::ELFSectionHeader; strtab = nothing, errstrtab = true)
        if strtab == nothing
            errstrtab && error("No Strtab given")
            return string("strtab@",header.sh_name)
        end
        return strtab_lookup(strtab,header.sh_name)
    end

    sizeof(header::ELFSectionHeader) = header.sh_size

    function secttype(sh_type::Uint32)
        if haskey(SHT_TYPES, sh_type)
            return SHT_TYPES[sh_type]
        end
        return string("Unknown (0x",hex(sh_type),")")
    end

    function show(io::IO, header::ELFSectionHeader; strtab = nothing, sections = nothing)
        printentry(io,"Name",sectionname(header;strtab=strtab,errstrtab=false))
        printentry(io,"Type",secttype(header.sh_type))
        printentry(io,"Size","0x",hex(header.sh_size))
        printentry(io,"Offset","0x",hex(header.sh_offset))
        printentry(io,"Load Address","0x",hex(header.sh_addr))
        if header.sh_link != 0
            target = ""
            if strtab !== nothing && sections !== nothing
                target = string(" -> ",sectionname(sections[header.sh_link+1].header; strtab = strtab))
            end
            printentry(io,"Link Section",header.sh_link,target)
        end
        if header.sh_link != 0
            target = ""
            if strtab !== nothing && sections !== nothing
                target = string(" -> ",sectionname(sections[header.sh_info+1].header; strtab = strtab))
            end
            printentry(io,"Info Section",header.sh_info,target)
        end
        flags = ASCIIString[]
        for (k,v) in SHF_FLAGS
            ((k&header.sh_flags) != 0) && push!(flags, v)
        end
        !isempty(flags) && printentry(io,"Flags",join(flags,","))
        printentry(io,"Align","0x",hex(header.sh_addralign))
        if header.sh_entsize != 0
            printentry(io,"Entry Size","0x",hex(header.sh_entsize))
        end
    end

    function filetype(e_type)
        if haskey(ET_TYPES, e_type)
            return ET_TYPES[e_type]
        end
        return string("Unknown (0x",hex(e_type),")")
    end
    function machinetype(e_machine)
        if haskey(EM_MACHINES, e_machine)
            return EM_MACHINES[e_machine]
        end
        return string("Unknown (0x",hex(e_machine),")")
    end
    function show(io::IO, header::ELFHeader)
        printentry(io,"Type",filetype(header.e_type))
        printentry(io,"Machine",machinetype(header.e_machine))
        # Skip e_version (not particularly useful)
        printentry(io,"Entrypoint","0x",hex(header.e_entry))
        printentry(io,"PH Offset","0x",hex(header.e_phoff))
        printentry(io,"SH Offset","0x",hex(header.e_shoff))
        # Skip flags
        printentry(io,"Header Size","0x",hex(header.e_ehsize))
        printentry(io,"PH Entry Size","0x",hex(header.e_phentsize))
        printentry(io,"PH Entry Count",dec(header.e_phnum))
        printentry(io,"SH Entry Size","0x",hex(header.e_shentsize))
        printentry(io,"SH Entry Count",dec(header.e_shnum))
        printentry(io,"Strtab Index",dec(header.e_shstrndx))
    end

    immutable SectionRef <: ObjFileBase.SectionRef{ELFHandle}
        handle::ELFHandle
        header::ELFSectionHeader
    end
    handle(sec::SectionRef) = sec.handle
    sectionname(sec::SectionRef; strtab=load_strtab(sec.handle), errstrtab = true) = sectionname(sec.header; strtab = strtab, errstrtab = true)
    show(io::IO, sr::SectionRef; strtab = load_strtab(sr.handle), sections = nothing) = show(io,sr.header; strtab = strtab, sections = sections)
    sizeof(s::SectionRef) = sizeof(s.header)
    deref(s::SectionRef) = s.header

    immutable StrTab
        strtab::SectionRef
    end
    strtab_lookup(s::StrTab,index) = strtab_lookup(s.strtab.handle,s.strtab.header,index)

    immutable Sections
        handle::ELFHandle
    end
    length(s::Sections) = s.handle.file.header.e_shnum
    function getindex(s::Sections, n)
        file = s.handle.file
        seek(s.handle,file.header.e_shoff + (n-1)*file.header.e_shentsize)
        SectionRef(s.handle, read(s.handle,ELFSectionHeader,file))
    end

    load_strtab(h::ELFHandle) = StrTab(Sections(h)[h.file.header.e_shstrndx+1])
    load_strtab(s::Sections) = StrTab(s[s.handle.file.header.e_shstrndx+1])
    load_strtab(s::SectionRef) = StrTab(s)
    const strtab = load_strtab

    start(s::Sections) = 1
    done(s::Sections,n) = n > length(s)
    next(s::Sections,n) = (s[n],n+1)

    function show(io::IO,s::Sections)
        println(io,"ELF Section Table")
        for section in s
            show(io,section; strtab=strtab(s), sections = s)
            println(io)
        end
    end

    link_sec(sec::SectionRef) = Sections(sec.handle)[sec.header.sh_link+1]
    info_sec(sec::SectionRef) = Sections(sec.handle)[sec.header.sh_info+1]

    # # Symbols
    immutable Symbols
        symtab::SectionRef
    end

    immutable SymbolRef <: ObjFileBase.SymbolRef{ELFHandle}
        handle::ELFHandle
        num::Uint16
        offset::Int
        entry::ELFSymtabEntry
    end
    symname(sym::SymbolRef; kwargs...) = symname(sym.entry; kwargs...)
    deref(ref::SymbolRef) = ref.entry

    function symname(sym::ELFSymtabEntry; strtab = nothing, errstrtab = true)
        if strtab == nothing
            errstrtab && error("No Strtab given")
            return string("strtab@",sym.st_name)
        end
        return strtab_lookup(strtab,sym.st_name)
    end

    st_bind(st_info) = st_info>>4
    st_type(st_info) = st_info & 0xf
    st_type(x::ELFSymtabEntry) = st_type(x.st_info)
    isglobal(x) = (st_bind(x.st_info) & STB_GLOBAL) != 0
    islocal(x) = !isglobal(x)
    isweak(x) = (st_bind(x.st_info) & STB_WEAK) != 0
    isdebug(x) = false

    # Try to follow the same format as llvm-objdump
    function showcompact(io::IO,x::ELFSymtabEntry; shstrtab = nothing, strtab = nothing, sections = nothing)
        # Value
        print(io,string("0x",hex(x.st_value,2*sizeof(x.st_value))))
        print(io," ")

        # Size
        print(io,string("0x",hex(x.st_size,2*sizeof(x.st_size))))
        print(io," ")

        # Symbol flags
        print(io, isglobal(x) ? "g" : islocal(x) ? "l" : "-")
        print(io, isweak(x) ? "w" : "-")
        print(io, "-"^3) # Unsupported
        print(io, isdebug(x) ? "d" : "-")
        STT = st_type(x)
        # Symbol type
        print(io, STT == STT_FILE ? "F" : STT == STT_FUNC ? "f" : STT == STT_OBJECT ? "O" : "-")

        print(io, " ")
        if x.st_shndx == SHN_UNDEF
            printfield(io,"*UND*",20; align = :left)
        elseif x.st_shndx == SHN_COMMON
            printfield(io,"*COM*",20; align = :left)
        elseif x.st_shndx == SHN_ABS
            printfield(io,"*ABS*",20; align = :left)
        elseif sections !== nothing
            printfield(io, sectionname(sections[x.st_shndx+1];
                strtab = shstrtab, errstrtab=true), 20; align = :left)
        else
            printfield(io, "Section #$(x.st_shndx)", 20; align = :left)
        end
        print(io, " ")

        print(io,symname(x; strtab = strtab, errstrtab = false))
    end

    function showcompact(io::IO,x::SymbolRef; shstrtab = load_strtab(x.handle), strtab = nothing, sections = Sections(x.handle))
        print(io,'[')
        printfield(io,dec(x.num),5)
        print(io,"] ")
        showcompact(io,x.entry; shstrtab = shstrtab, strtab=strtab, sections = sections)
    end

    function show(io::IO, s::Symbols)
        h = s.symtab.handle
        shstrtab = strtab(h)
        symstrtab = strtab(Sections(h)[s.symtab.header.sh_link+1])
        for sym in s
            showcompact(io, sym; shstrtab = shstrtab, strtab = symstrtab)
            println(io)
        end
    end

    SymtabEntrySize(s::Symbols) =
        StrPack.calcsize(symtype(typeof(s.symtab.header)))
    endof(s::Symbols) = div(s.symtab.header.sh_size,SymtabEntrySize(s))
    function getindex(s::Symbols,n)
        if n < 1 || n > endof(s)
            throw(BoundsError())
        end
        h = s.symtab.handle
        offset = s.symtab.header.sh_offset + (n-1)*SymtabEntrySize(s)
        seek(h,offset)
        SymbolRef(h,n,offset,unpack(h, symtype(typeof(s.symtab.header))))
    end

    start(s::Symbols) = 1
    done(s::Symbols,n) = n > endof(s)
    next(s::Symbols,n) = (x=s[n];(x,n+1))

    # Access to relocations
    immutable Relocations{T <: ELFRel}
        sec::SectionRef
    end
    function Relocations(sec::SectionRef)
        is64 = isa(sec.handle.file,ELF64.File)
        isRela = sec.header.sh_type == SHT_RELA
        Relocations{is64 ? (isRela ? ELF64.Rela : ELF64.Rel) : (isRelA ? ELF32.Rela : ELF32.ReL)}(sec)
    end

    immutable RelocationRef{T <: ELFRel}
        h::ELFHandle
        reloc::T
    end

    deref(x::RelocationRef) = x.reloc

    entrysize{T}(s::Relocations{T}) = StrPack.calcsize(T)
    endof{T}(s::Relocations{T}) = div(s.sec.header.sh_size,entrysize(s))
    length(r::Relocations) = endof(r)
    function getindex{T}(s::Relocations{T},n)
        if n < 1 || n > length(s)
            throw(BoundsError())
        end
        offset = sectionoffset(s.sec) + (n-1)*entrysize(s)
        seek(s.sec.handle,offset)
        RelocationRef{T}(s.sec.handle,unpack(s.sec.handle, T))
    end


    start(s::Relocations) = 1
    done(s::Relocations,n) = n > length(s)
    next(s::Relocations,n) = (x=s[n];(x,n+1))


    # DWARF support
    function read(io::IO,file::ELFFile,h::ELFSectionHeader,::Type{DWARF.ARTable})
        seek(io,h.sh_offset)
        ret = DWARF.ARTable(Array(DWARF.ARTableSet,0))
        while position(io) < h.sh_offset + h.sh_size
            push!(ret.sets,read(io,DWARF.ARTableSet,f.endianness))
        end
        ret
    end

    function read(io::IO,file::ELFFile,h::ELFSectionHeader,::Type{DWARF.PUBTable})
        seek(io,h.sh_offset)
        ret = DWARF.PUBTable(Array(DWARF.PUBTableSet,0))
        while position(io) < h.sh_offset + h.sh_size
            push!(ret.sets,read(io,DWARF.PUBTableSet,f.endianness))
        end
        ret
    end

    function read(io::IO,f::ELFFile,h::ELFSectionHeader,::Type{DWARF.AbbrevTableSet})
        seek(io,h.sh_offset)
        read(io,AbbrevTableSet,f.endianness)
    end

    function read(io::IO,f::ELFFile,h::ELFSectionHeader,s::DWARF.PUBTableSet,::Type{DWARF.DWARFCUHeader})
        seek(io,h.sh_offset+s.header.debug_info_offset)
        read(io,DWARF.DWARFCUHeader,f.endianness)
    end

    function read(io::IO,f::ELFFile,debug_info::ELFSectionHeader,debug_abbrev::ELFSectionHeader,
        s::DWARF.PUBTableSet,e::DWARF.PUBTableEntry,header::DWARF.DWARFCUHeader,::Type{DWARF.DIE})
        ats = read(io,f,debug_abbrev,header,DWARF.AbbrevTableSet)
        seek(io,debug_info.sh_offset+s.header.debug_info_offset+e.offset)
        read(io,header,ats,DWARF.DIE)
    end

    function read(io::IO,f::ELFFile,h::ELFSectionHeader,s::DWARF.DWARFCUHeader,::Type{DWARF.AbbrevTableSet})
        seek(io,h.sh_offset+s.debug_abbrev_offset)
        read(io,AbbrevTableSet,f.endianness)
    end

    function debugsections(io::IO,f::ELFFile)
        snames = names(io,f,f.sheaders)
        sections = Dict{ASCIIString,ELFSectionHeader}()
        for i in 1:length(snames)
            # Remove leading "."
            ind = findfirst(DEBUG_SECTIONS,snames[i][2:end])
            if ind != 0
                sections[DEBUG_SECTIONS[ind]] = f.sheaders[ind]
            end
        end
        sections
    end

    function read(io::IO,f::ELFFile,debug_info::ELFSectionHeader,debug_abbrev::ELFSectionHeader,
        s::DWARF.PUBTableSet,e::DWARF.PUBTableEntry,header::DWARF.DWARFCUHeader,::Type{DWARF.DIETree})
        ats = read(io,f,debug_abbrev,header,DWARF.AbbrevTableSet)
        seek(io,debug_info.sh_offset+s.header.debug_info_offset+e.offset)
        ret = DIETree(Array(DWARF.DIETreeNode,0))
        read(io,header,ats,ret,DWARF.DIETreeNode,f.endianness)
        ret
    end

    immutable dl_phdr_info
        dlpi_addr::Uint64
        dlpi_name::Ptr{Uint8}
        dlpi_phdr::Ptr{Void}
        dlpi_phnum::Uint16
    end

    function callback(info::Ptr{dl_phdr_info},size::Csize_t, data::Ptr{Void})
        push!(unsafe_pointer_to_objref(data),unsafe_load(info))
        convert(Cint,0)
    end

    function loaded_libraries()
        x = Array(dl_phdr_info,0)
        ccall(:dl_iterate_phdr, Cint, (Ptr{Void}, Any), cfunction(callback, Cint, (Ptr{dl_phdr_info},Csize_t,Ptr{Void})), x)
        x
    end

    ## DWARF Support

    using DWARF

    function debugsections(h::ELFHandle)
        sects = collect(Sections(h))
        strt = strtab(h)
        snames = map(s->sectionname(s.header;strtab=strt),sects)
        sections = Dict{ASCIIString,SectionRef}()
        for i in 1:length(snames)
            # remove leading "."
            ind = findfirst(DWARF.DEBUG_SECTIONS,bytestring(snames[i])[2:end])
            if ind != 0
                sections[DWARF.DEBUG_SECTIONS[ind]] = sects[i]
            end
        end
        ObjFileBase.DebugSections(h,sections)
    end

    # JIT Utils
    function replace_sections_from_memory(h::ELFHandle, new_buffer)
        for sec in Sections(h)
            if ObjFileBase.is_jit_section(sec)
                seek(new_buffer,sectionoffset(sec))
                write(new_buffer,pointer_to_array(
                    reinterpret(Ptr{Uint8},sectionaddress(sec)),
                    sectionsize(sec),false))
            end
        end
        seekstart(new_buffer)
        new_buffer
    end

    # Other things
    include("relocate.jl")
end

